use flier_common::errno_atom;
use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
use rustler::env::SavedTerm;
use rustler::{Atom, Encoder, Env, LocalPid, OwnedEnv, Resource, ResourceArc};
use std::os::unix::ffi::OsStrExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

rustler::atoms! {
    stopped,
    inotify_event,
}

/// Handle to the background reader thread.
///
/// The thread blocks in `read(2)` on the inotify fd. To stop it we set
/// `running` to false and remove the watch: the kernel then queues an
/// `IN_IGNORED` event, which wakes the thread immediately so it can observe
/// the flag and exit. This keeps `stop_watcher/1` (and `Drop`) fast instead
/// of waiting for a poll timeout.
struct WatcherResourceInner {
    running: Arc<AtomicBool>,
    watches: Watches,
    wd: WatchDescriptor,
    watcher: Option<thread::JoinHandle<()>>,
}

impl WatcherResourceInner {
    fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(watcher) = self.watcher.take() {
            // Fails with EINVAL if the watch is already gone (e.g. the watched
            // directory was deleted); the thread has then exited on its own
            // after receiving IN_IGNORED.
            let _ = self.watches.remove(self.wd.clone());
            let _ = watcher.join();
        }
    }
}

struct WatcherResource {
    inner: Mutex<WatcherResourceInner>,
}

#[rustler::resource_impl]
impl Resource for WatcherResource {}

impl Drop for WatcherResource {
    fn drop(&mut self) {
        // Guarantee the background thread is stopped and joined when the
        // resource is garbage-collected, even if the caller never invoked
        // `stop_watcher/1`. Proceed even if the lock is poisoned.
        let mut inner = match self.inner.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        inner.stop();
    }
}

/// Start watching `path`. Returns `{:ok, resource}` or `{:error, errno}`
/// with a POSIX errno atom such as `:enoent`, `:eacces` or `:enospc`.
#[rustler::nif(schedule = "DirtyIo")]
fn start_watcher(
    env: Env,
    path: rustler::Binary,
    event_list: Vec<Atom>,
    pid: LocalPid,
    tag: rustler::Term,
) -> Result<ResourceArc<WatcherResource>, Atom> {
    let inotify = Inotify::init().map_err(|e| errno_atom(env, &e))?;
    let mut watches = inotify.watches();
    let event_names: Vec<String> = event_list
        .iter()
        .filter_map(|atom| atom.to_term(env).atom_to_string().ok())
        .collect();
    let wd = watches
        .add(
            std::ffi::OsStr::from_bytes(path.as_slice()),
            build_watch_mask(event_names.iter().map(String::as_str)),
        )
        .map_err(|e| errno_atom(env, &e))?;

    // The tag is copied into an env owned by the thread; it cannot be the
    // resource itself, as the thread holding it would keep the resource alive.
    let tag_env = OwnedEnv::new();
    let tag = tag_env.save(tag);

    let running = Arc::new(AtomicBool::new(true));
    let thread_running = running.clone();
    let watcher = thread::spawn(move || read_loop(inotify, pid, (tag_env, tag), thread_running));

    let resource = ResourceArc::new(WatcherResource {
        inner: Mutex::new(WatcherResourceInner {
            running,
            watches,
            wd,
            watcher: Some(watcher),
        }),
    });

    Ok(resource)
}

/// Blocking read loop run on the watcher thread. Exits when stopped, when
/// the recipient process is gone, on read errors, or once the watch has been
/// removed by the kernel (`IN_IGNORED`) since no further events can arrive.
fn read_loop(
    mut inotify: Inotify,
    pid: LocalPid,
    (tag_env, tag): (OwnedEnv, SavedTerm),
    running: Arc<AtomicBool>,
) {
    let mut owned_env = OwnedEnv::new();
    let mut buffer = [0u8; 4096];

    while running.load(Ordering::SeqCst) {
        let events = match inotify.read_events_blocking(&mut buffer) {
            Ok(events) => events,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        };

        for event in events {
            if !running.load(Ordering::SeqCst) {
                return;
            }

            // Preserve the raw bytes of the filename: Linux filenames are
            // arbitrary byte sequences, so they are sent as an Erlang binary
            // rather than a lossily converted string.
            let name: &[u8] = event.name.map(|n| n.as_bytes()).unwrap_or_default();
            let names = mask_names(event.mask);

            let sent = owned_env.send_and_clear(&pid, |env| {
                let mut bin = rustler::OwnedBinary::new(name.len())
                    .expect("failed to allocate OwnedBinary for filename");
                bin.as_mut_slice().copy_from_slice(name);
                let tag = tag_env.run(|tag_env| tag.load(tag_env).in_env(env));
                let masks: Vec<Atom> = names
                    .iter()
                    .map(|name| Atom::from_str(env, name).expect("event names are valid atoms"))
                    .collect();
                (inotify_event(), tag, bin.release(env), masks).encode(env)
            });

            if sent.is_err() || event.mask.contains(EventMask::IGNORED) {
                return;
            }
        }
    }
}

/// Stop watcher via resource handle
#[rustler::nif]
fn stop_watcher(resource: ResourceArc<WatcherResource>) -> Atom {
    let mut inner = match resource.inner.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    inner.stop();
    stopped()
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
}
