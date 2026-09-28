use inotify::{EventMask, Inotify, WatchDescriptor, WatchMask, Watches};
use rustler::env::SavedTerm;
use rustler::{Atom, Encoder, Error, LocalPid, NifResult, OwnedEnv, Resource, ResourceArc};
use std::os::unix::ffi::OsStrExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

rustler::atoms! {
    ok,
    stopped,
    init_failed,
    failed_to_add_watcher,
    no_pid,
    // event type
    inotify_event,
    // inotify events
    create,
    modify,
    delete,
    moved_from,
    moved_to,
    access,
    close_write,
    close_nowrite,
    open,
    attrib,
    ignored,
    isdir,
    unknown
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

#[rustler::nif(schedule = "DirtyIo")]
fn start_watcher(
    path: String,
    event_list: Vec<Atom>,
    pid: rustler::Term,
    tag: rustler::Term,
) -> NifResult<(Atom, ResourceArc<WatcherResource>)> {
    let pid = pid
        .decode::<LocalPid>()
        .map_err(|_| Error::Term(Box::new(no_pid())))?;

    let inotify = Inotify::init().map_err(|_| Error::Term(Box::new(init_failed())))?;
    let mut watches = inotify.watches();
    let wd = watches
        .add(&path, build_watch_mask(&event_list))
        .map_err(|_| Error::Term(Box::new(failed_to_add_watcher())))?;

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

    Ok((ok(), resource))
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
            let mask_atoms = mask_to_atoms(event.mask);

            let sent = owned_env.send_and_clear(&pid, |env| {
                let mut bin = rustler::OwnedBinary::new(name.len())
                    .expect("failed to allocate OwnedBinary for filename");
                bin.as_mut_slice().copy_from_slice(name);
                let tag = tag_env.run(|tag_env| tag.load(tag_env).in_env(env));
                (inotify_event(), tag, bin.release(env), mask_atoms).encode(env)
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

fn build_watch_mask(event_atoms: &[Atom]) -> WatchMask {
    let mut mask = WatchMask::empty();

    for atom in event_atoms {
        if *atom == create() {
            mask |= WatchMask::CREATE;
        } else if *atom == modify() {
            mask |= WatchMask::MODIFY;
        } else if *atom == delete() {
            mask |= WatchMask::DELETE;
        } else if *atom == moved_from() {
            mask |= WatchMask::MOVED_FROM;
        } else if *atom == moved_to() {
            mask |= WatchMask::MOVED_TO;
        } else if *atom == access() {
            mask |= WatchMask::ACCESS;
        } else if *atom == attrib() {
            mask |= WatchMask::ATTRIB;
        } else if *atom == close_write() {
            mask |= WatchMask::CLOSE_WRITE;
        } else if *atom == close_nowrite() {
            mask |= WatchMask::CLOSE_NOWRITE;
        } else if *atom == open() {
            mask |= WatchMask::OPEN;
        }
    }

    mask
}

fn mask_to_atoms(mask: EventMask) -> Vec<Atom> {
    let mut atoms = Vec::new();

    if mask.contains(EventMask::CREATE) {
        atoms.push(create());
    }
    if mask.contains(EventMask::MODIFY) {
        atoms.push(modify());
    }
    if mask.contains(EventMask::DELETE) {
        atoms.push(delete());
    }
    if mask.contains(EventMask::MOVED_FROM) {
        atoms.push(moved_from());
    }
    if mask.contains(EventMask::MOVED_TO) {
        atoms.push(moved_to());
    }
    if mask.contains(EventMask::ACCESS) {
        atoms.push(access());
    }
    if mask.contains(EventMask::ATTRIB) {
        atoms.push(attrib());
    }
    if mask.contains(EventMask::CLOSE_WRITE) {
        atoms.push(close_write());
    }
    if mask.contains(EventMask::CLOSE_NOWRITE) {
        atoms.push(close_nowrite());
    }
    if mask.contains(EventMask::OPEN) {
        atoms.push(open());
    }
    if mask.contains(EventMask::IGNORED) {
        atoms.push(ignored());
    }
    if mask.contains(EventMask::ISDIR) {
        atoms.push(isdir());
    }

    if atoms.is_empty() {
        atoms.push(unknown());
    }

    atoms
}
