// extern crate inotify;

use inotify::{EventMask, Inotify, WatchMask};
use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
use rustler::{
    Atom, Encoder, Env, Error, LocalPid, Monitor, NifResult, OwnedEnv, Resource, ResourceArc, Term,
};
use std::os::unix::io::AsFd;

use std::boxed::Box;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use std::thread;

rustler::atoms! {
    ok,
    error,
    // none,
    stopped,
    init_failed,
    failed_to_add_watcher,
    inotify_error,
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

/// A resource that holds the thread stop flag and join handle
// #[derive(Resource)]
struct WatcherResourceInner {
    running: Arc<AtomicBool>,
    watcher: Option<thread::JoinHandle<()>>, // down_called: bool,
}

struct WatcherResource {
    inner: Mutex<WatcherResourceInner>,
}

// #[rustler::resource_impl(register = true, name = "monitor")]
#[rustler::resource_impl]
impl Resource for WatcherResource {
    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _mon: Monitor) {
        let mut inner = self.inner.lock().unwrap();
        // Stop thread when GC’d
        inner.running.store(false, Ordering::SeqCst);
        if let Some(watcher) = inner.watcher.take() {
            let _ = watcher.join();
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn start_watcher<'a>(
    path: String,
    event_list: Vec<Atom>,
    pid_term: Term<'a>,
) -> NifResult<(Atom, ResourceArc<WatcherResource>)> {
    let (tx, rx) = mpsc::channel();

    let pid = pid_term
        .decode::<LocalPid>()
        .map_err(|_| Error::Term(Box::new(no_pid())))?;

    let mask = build_watch_mask(&event_list);

    // Shared flag to stop the thread if the process dies
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();

    let watcher = thread::spawn(move || {
        let mut owned_env = OwnedEnv::new();
        let mut inotify = match Inotify::init() {
            Ok(i) => i,
            Err(_err) => {
                let _ = tx.send(Err(init_failed()));

                return;
            }
        };

        if let Err(_err) = inotify.watches().add(&path, mask) {
            let _ = tx.send(Err(failed_to_add_watcher()));
            return;
        }
        let _ = tx.send(Ok(ok()));

        let mut buffer = [0; 1024];

        // Use poll() for efficient waiting instead of busy-polling
        let poll_timeout = PollTimeout::from(100u16); // 100ms timeout

        while running_clone.load(Ordering::SeqCst) {
            // Create PollFd for the inotify file descriptor
            let mut poll_fds = [PollFd::new(inotify.as_fd(), PollFlags::POLLIN)];

            match poll(&mut poll_fds, poll_timeout) {
                Ok(0) => {
                    // Timeout - no events, loop back to check running flag
                    continue;
                }
                Ok(_) => {
                    // Events available, read them
                    match inotify.read_events(&mut buffer) {
                        Ok(events) => {
                            for event in events {
                                let filename = event
                                    .name
                                    .and_then(|os_str| os_str.to_str().map(|s| s.to_string()))
                                    .unwrap_or_else(|| "".to_string());

                                let mask_atoms = mask_to_atoms(event.mask);

                                let sent = OwnedEnv::send_and_clear(&mut owned_env, &pid, |env| {
                                    (inotify_event(), filename, mask_atoms).encode(env)
                                });
                                if sent.is_err() {
                                    running_clone.store(false, Ordering::SeqCst);
                                }

                                if !running_clone.load(Ordering::SeqCst) {
                                    break;
                                }
                            }
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            // Spurious wakeup, continue polling
                            continue;
                        }
                        Err(_err) => {
                            // inotify read error, exit loop
                            break;
                        }
                    }
                }
                Err(_) => {
                    // Poll error, exit loop
                    break;
                }
            }
        }
    });

    match rx.recv() {
        Ok(Ok(_)) => {
            let resource = ResourceArc::new(WatcherResource {
                inner: Mutex::new(WatcherResourceInner {
                    running,
                    watcher: Some(watcher), // down_called: false,
                }),
            });

            Ok((ok(), resource))
        }
        Ok(Err(msg)) => {
            // eprintln!("Watcher startup failed: {}", msg);
            Err(Error::Term(Box::new(msg)))
        }
        Err(_) => {
            eprintln!("Failed to receive watcher startup result");
            Err(Error::Term(Box::new(error())))
        }
    }
}

/// Stop watcher via resource handle
#[rustler::nif]
fn stop_watcher(resource: ResourceArc<WatcherResource>) -> Atom {
    let mut inner = resource.inner.lock().unwrap();
    // resource.running.store(false, Ordering::SeqCst);
    inner.running.store(false, Ordering::SeqCst);

    if let Some(watcher) = inner.watcher.take() {
        let _ = watcher.join();
    }

    stopped()
}

// rustler::init!("Elixir.Flier.Inotify", [start_watcher]);
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
