use flier_common::errno_atom;
use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
use rustler::env::SavedTerm;
use rustler::{
    Atom, Binary, Encoder, Env, LocalPid, NewBinary, OwnedEnv, Resource, ResourceArc, Term,
};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::thread;

rustler::atoms! {
    stopped,
    inotify_event,
    inotify_error,
}

/// `%Flier.Inotify.Event{}`. The name is the raw bytes from the kernel, as
/// Linux filenames are arbitrary byte sequences.
#[derive(rustler::NifStruct)]
#[module = "Flier.Inotify.Event"]
struct Event<'a> {
    name: Binary<'a>,
    masks: Vec<Atom>,
    cookie: u32,
}

/// A watcher: a process subscribed to the events of one kernel watch.
struct Subscriber {
    id: u64,
    pid: LocalPid,
    /// The watcher's ref, kept in an env of its own. It cannot be the
    /// resource itself, as holding that would keep the resource alive.
    tag: (OwnedEnv, SavedTerm),
    /// The events the watcher subscribed to.
    events: EventMask,
}

/// The inotify instance shared by all watchers, read by a single thread.
///
/// Watchers on the same inode share its kernel watch: it is added with
/// `IN_MASK_ADD`, so its mask is the union of theirs, and each watcher is
/// only sent the events it subscribed to. A kernel watch exists exactly as
/// long as it has subscribers; removing the last one removes the watch.
///
/// The hub lives while it has watches. Removing a watch makes the kernel
/// queue `IN_IGNORED`, which wakes the reader thread; when it finds no
/// subscribers left it drops the hub, closing the instance, and exits. The
/// next watcher then starts a new one.
///
/// Events are only sent while holding the hub lock, so once a watcher has
/// been unsubscribed no further events reach it.
struct Hub {
    watches: Watches,
    subscribers: HashMap<WatchDescriptor, Vec<Subscriber>>,
}

static HUB: Mutex<Option<Hub>> = Mutex::new(None);
static NEXT_ID: AtomicU64 = AtomicU64::new(0);

/// Lock the hub, even if a panic poisoned the lock.
fn lock_hub() -> MutexGuard<'static, Option<Hub>> {
    HUB.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A watcher's handle on its subscription.
struct WatcherResource {
    id: u64,
    wd: WatchDescriptor,
}

#[rustler::resource_impl]
impl Resource for WatcherResource {}

impl Drop for WatcherResource {
    fn drop(&mut self) {
        // Stop the watcher when the resource is garbage-collected, even if
        // the caller never invoked `stop_watcher/1`.
        unsubscribe(self.id, &self.wd);
    }
}

/// Start watching `path`. Returns `{:ok, resource}` or `{:error, errno}`
/// with a POSIX errno atom such as `:enoent`, `:eacces` or `:enospc`.
#[rustler::nif(schedule = "DirtyIo")]
fn start_watcher(
    env: Env,
    path: Binary,
    event_list: Vec<Atom>,
    pid: LocalPid,
    tag: Term,
) -> Result<ResourceArc<WatcherResource>, Atom> {
    let event_names: Vec<String> = event_list
        .iter()
        .filter_map(|atom| atom.to_term(env).atom_to_string().ok())
        .collect();
    let mask = build_watch_mask(event_names.iter().map(String::as_str));
    let path = OsStr::from_bytes(path.as_slice());

    let mut guard = lock_hub();
    let (hub, wd) = match guard.as_mut() {
        Some(hub) => {
            let wd = hub
                .watches
                .add(path, mask | WatchMask::MASK_ADD)
                .map_err(|e| errno_atom(env, &e))?;
            (hub, wd)
        }
        None => {
            let (hub, wd) = start_hub(path, mask).map_err(|e| errno_atom(env, &e))?;
            (guard.insert(hub), wd)
        }
    };

    let tag_env = OwnedEnv::new();
    let tag = tag_env.save(tag);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);

    hub.subscribers
        .entry(wd.clone())
        .or_default()
        .push(Subscriber {
            id,
            pid,
            tag: (tag_env, tag),
            events: EventMask::from_bits_truncate(mask.bits()),
        });
    drop(guard);

    Ok(ResourceArc::new(WatcherResource { id, wd }))
}

/// Create the inotify instance with a first watch on `path`, and its reader
/// thread. The watch is added first so that no thread is started for a path
/// that cannot be watched: the thread only exits once a watch is removed.
fn start_hub(path: &OsStr, mask: WatchMask) -> std::io::Result<(Hub, WatchDescriptor)> {
    let inotify = Inotify::init()?;
    let mut watches = inotify.watches();
    let wd = watches.add(path, mask)?;

    thread::Builder::new()
        .name("flier_inotify".into())
        .spawn(move || read_loop(inotify))?;

    let hub = Hub {
        watches,
        subscribers: HashMap::new(),
    };
    Ok((hub, wd))
}

/// Stop watcher via resource handle. Idempotent. Runs on a dirty scheduler
/// as it takes the hub lock and removes the kernel watch.
#[rustler::nif(schedule = "DirtyIo")]
fn stop_watcher(resource: ResourceArc<WatcherResource>) -> Atom {
    unsubscribe(resource.id, &resource.wd);
    stopped()
}

/// Remove a subscriber, and its kernel watch if it was the last one on it.
fn unsubscribe(id: u64, wd: &WatchDescriptor) {
    let mut guard = lock_hub();
    let Some(hub) = guard.as_mut() else {
        return;
    };
    let Some(subscribers) = hub.subscribers.get_mut(wd) else {
        return;
    };

    subscribers.retain(|sub| sub.id != id);
    if subscribers.is_empty() {
        hub.remove_watch(wd);
    }
}

impl Hub {
    /// Forget a watch and remove it from the kernel. Removal fails with
    /// EINVAL if the kernel already dropped the watch, which is fine.
    fn remove_watch(&mut self, wd: &WatchDescriptor) {
        self.subscribers.remove(wd);
        let _ = self.watches.remove(wd.clone());
    }

    /// Send an event to the subscribers that want it.
    fn dispatch(&mut self, env: &mut OwnedEnv, event: &inotify::Event<&OsStr>) {
        if event.mask.contains(EventMask::Q_OVERFLOW) {
            // Not tied to a watch: every watcher may have missed events.
            let wds: Vec<WatchDescriptor> = self.subscribers.keys().cloned().collect();
            for wd in &wds {
                self.deliver(env, wd, event);
            }
        } else {
            self.deliver(env, &event.wd, event);
        }

        if event.mask.contains(EventMask::IGNORED) {
            // The kernel removed the watch; no further events can arrive.
            self.subscribers.remove(&event.wd);
        }
    }

    /// Send `event` to the subscribers of `wd` that want it, dropping those
    /// whose process is gone.
    fn deliver(
        &mut self,
        env: &mut OwnedEnv,
        wd: &WatchDescriptor,
        event: &inotify::Event<&OsStr>,
    ) {
        let Some(subscribers) = self.subscribers.get_mut(wd) else {
            return;
        };

        let names = mask_names(event.mask);
        let name = event.name.map(OsStr::as_bytes).unwrap_or_default();

        subscribers.retain(|sub| {
            !wants(sub.events, event.mask)
                || env
                    .send_and_clear(&sub.pid, |env| {
                        let mut bin = NewBinary::new(env, name.len());
                        bin.as_mut_slice().copy_from_slice(name);
                        let masks: Vec<Atom> = names
                            .iter()
                            .map(|name| {
                                Atom::from_str(env, name).expect("event names are valid atoms")
                            })
                            .collect();
                        let msg = Event {
                            name: bin.into(),
                            masks,
                            cookie: event.cookie,
                        };
                        (inotify_event(), sub.tag(env), msg).encode(env)
                    })
                    .is_ok()
        });

        if subscribers.is_empty() {
            self.remove_watch(wd);
        }
    }

    /// Tell every subscriber that no further events will arrive, so none
    /// waits forever.
    fn broadcast_error(&self, env: &mut OwnedEnv, err: &std::io::Error) {
        for sub in self.subscribers.values().flatten() {
            let _ = env.send_and_clear(&sub.pid, |env| {
                (inotify_error(), sub.tag(env), errno_atom(env, err)).encode(env)
            });
        }
    }
}

impl Subscriber {
    /// The watcher's ref, copied into `env`.
    fn tag<'a>(&self, env: Env<'a>) -> Term<'a> {
        let (tag_env, tag) = &self.tag;
        tag_env.run(|tag_env| tag.load(tag_env).in_env(env))
    }
}

/// Whether a watcher subscribed to `subscribed` wants an event with `mask`.
/// The flags the kernel reports unasked concern every watcher.
fn wants(subscribed: EventMask, mask: EventMask) -> bool {
    let unasked = EventMask::IGNORED | EventMask::Q_OVERFLOW | EventMask::UNMOUNT;
    mask.intersects(subscribed | unasked)
}

/// Blocking read loop run on the reader thread. Exits once no watchers are
/// left, or on a read error after sending `{:inotify_error, tag, errno}` to
/// every watcher; either way the hub is dropped.
fn read_loop(mut inotify: Inotify) {
    let mut env = OwnedEnv::new();
    let mut buffer = [0u8; 4096];

    loop {
        let events = match inotify.read_events_blocking(&mut buffer) {
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            events => events,
        };

        let mut guard = lock_hub();
        let Some(hub) = guard.as_mut() else {
            return;
        };

        match events {
            Ok(events) => {
                for event in events {
                    hub.dispatch(&mut env, &event);
                }
                if !hub.subscribers.is_empty() {
                    continue;
                }
            }
            Err(e) => hub.broadcast_error(&mut env, &e),
        }

        *guard = None;
        return;
    }
}

rustler::init!("Elixir.Flier.Inotify.Native");

/// Subscribable events: Elixir atom name, inotify watch flag, and event flag.
const EVENTS: [(&str, WatchMask, EventMask); 10] = [
    ("create", WatchMask::CREATE, EventMask::CREATE),
    ("modify", WatchMask::MODIFY, EventMask::MODIFY),
    ("delete", WatchMask::DELETE, EventMask::DELETE),
    ("moved_from", WatchMask::MOVED_FROM, EventMask::MOVED_FROM),
    ("moved_to", WatchMask::MOVED_TO, EventMask::MOVED_TO),
    ("access", WatchMask::ACCESS, EventMask::ACCESS),
    ("attrib", WatchMask::ATTRIB, EventMask::ATTRIB),
    (
        "close_write",
        WatchMask::CLOSE_WRITE,
        EventMask::CLOSE_WRITE,
    ),
    (
        "close_nowrite",
        WatchMask::CLOSE_NOWRITE,
        EventMask::CLOSE_NOWRITE,
    ),
    ("open", WatchMask::OPEN, EventMask::OPEN),
];

/// Flags the kernel reports without being subscribed to.
const REPORT_ONLY: [(&str, EventMask); 4] = [
    ("ignored", EventMask::IGNORED),
    ("isdir", EventMask::ISDIR),
    ("q_overflow", EventMask::Q_OVERFLOW),
    ("unmount", EventMask::UNMOUNT),
];

/// Build the watch mask; unknown names are ignored (validated in Elixir).
fn build_watch_mask<'a>(names: impl IntoIterator<Item = &'a str>) -> WatchMask {
    let names: Vec<&str> = names.into_iter().collect();

    EVENTS
        .iter()
        .filter(|(name, _, _)| names.contains(name))
        .fold(WatchMask::empty(), |mask, (_, flag, _)| mask | *flag)
}

/// Names of the flags set in an event mask, or `["unknown"]` if none is
/// recognised.
fn mask_names(mask: EventMask) -> Vec<&'static str> {
    let events = EVENTS.iter().map(|(name, _, flag)| (*name, *flag));
    let report_only = REPORT_ONLY.iter().copied();

    let names: Vec<&'static str> = events
        .chain(report_only)
        .filter(|(_, flag)| mask.contains(*flag))
        .map(|(name, _)| name)
        .collect();

    if names.is_empty() {
        vec!["unknown"]
    } else {
        names
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subscribed_events_are_named() {
        assert_eq!(
            mask_names(EventMask::CREATE | EventMask::ISDIR),
            ["create", "isdir"]
        );
    }

    #[test]
    fn queue_overflow_is_reported() {
        assert_eq!(mask_names(EventMask::Q_OVERFLOW), ["q_overflow"]);
    }

    #[test]
    fn unmount_is_reported() {
        assert_eq!(
            mask_names(EventMask::UNMOUNT | EventMask::IGNORED),
            ["ignored", "unmount"]
        );
    }

    #[test]
    fn unrecognised_flags_are_unknown() {
        assert_eq!(mask_names(EventMask::empty()), ["unknown"]);
    }

    #[test]
    fn watch_mask_from_names() {
        assert_eq!(
            build_watch_mask(["create", "close_write", "isdir", "bogus"]),
            WatchMask::CREATE | WatchMask::CLOSE_WRITE
        );
    }

    #[test]
    fn watchers_want_only_their_events() {
        assert!(wants(
            EventMask::CREATE,
            EventMask::CREATE | EventMask::ISDIR
        ));
        assert!(!wants(
            EventMask::CREATE,
            EventMask::DELETE | EventMask::ISDIR
        ));
    }

    #[test]
    fn watchers_want_unasked_flags() {
        for flag in [
            EventMask::IGNORED,
            EventMask::Q_OVERFLOW,
            EventMask::UNMOUNT,
        ] {
            assert!(wants(EventMask::CREATE, flag));
        }
    }
}
