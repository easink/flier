// extern crate inotify;

use inotify::{EventMask, Inotify, WatchMask};
// use rustler::resource::ResourceArc;
use rustler::{
    Atom, Encoder, Env, Error, LocalPid, Monitor, NifResult, OwnedEnv, Resource, ResourceArc, Term,
};

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
        // let mut inner = self.inner.lock().unwrap();
        // assert!(Some(watcher) == inner.watcher);
        // inner.down_called = true;
        //
        println!("cleanup watcher resource\r\n");
        let mut inner = self.inner.lock().unwrap();
        // Stop thread when GC’d
        inner.running.store(false, Ordering::SeqCst);
        // assert!(Some(watcher) == inner.watcher);
        if let Some(watcher) = inner.watcher.take() {
            let _ = watcher.join();
        }
        // if let Some(watcher) = self.watcher.lock().unwrap().take() {
        //     let _ = watcher.join();
        // }
        println!("cleaned up watcher resource\r\n");
    }
}

// impl Drop for WatcherResource {
//     fn drop(&mut self) {
//         // Stop thread when GC’d
//         self.running.store(false, Ordering::SeqCst);
//         println!("drop1\r\n");
//         if let Some(watcher) = self.watcher.lock().unwrap().take() {
//             let _ = watcher.join();
//         }
//         println!("drop2\r\n");
//     }
// }

// impl Drop for WatcherResource {
//     fn drop(&mut self) {
//         println!("drop1\r\n");
//         let mut inner = self.inner.lock().unwrap();
//         // Stop thread when GC’d
//         inner.running.store(false, Ordering::SeqCst);
//         // assert!(Some(watcher) == inner.watcher);
//         if let Some(watcher) = inner.watcher.take() {
//             let _ = watcher.join();
//         }
//         println!("drop2\r\n");
//     }
// }

// impl Resource for WatcherResourceInner {}

// impl Resource for WatcherResource {}

// #[rustler::nif]
// // fn on_load(env: Env, _: Term) -> bool {
// fn on_load(env: Env) -> bool {
//     println!("ONLOAD");
//     // let _ = rustler::resource!(WatcherResource, env);
//     // rustler::resource!(WatcherResource, env) && env.register::<WatcherResource>().is_ok();
//     env.register::<WatcherResource>().is_ok();

//     true
// }

#[rustler::nif(schedule = "DirtyIo")]
// fn start_watcher<'a>(_env: env<'a>, path: string, pid: term<'a>) -> rustler::atom {
// fn start_watcher<'a>(path: String, pid: Term<'a>) -> Atom {
fn start_watcher<'a>(
    path: String,
    event_list: Vec<Atom>,
    pid_term: Term<'a>,
) -> NifResult<(Atom, ResourceArc<WatcherResource>)> {
    // let pid = pid.decode::<rustler::types::Pid>().unwrap();
    // let pid = pid.decode::<rustler::TermType::Pid>().unwrap();
    let (tx, rx) = mpsc::channel();

    println!("start1\r\n");
    // let pid = pid_term.decode::<LocalPid>().map_err(|_| Error::BadArg)?;
    let pid = pid_term
        .decode::<LocalPid>()
        .map_err(|_| Error::Term(Box::new(no_pid())))?;

    // pid.monitor_process();

    // Ok((ok(), resource))
    // .map_err(|_| rustler::Error::Term(Box::new(error())))?;
    println!("start2\r\n");
    let mask = build_watch_mask(&event_list);
    // let pid = pid_term.decode::<LocalPid>().unwrap();
    // let path_clone = path.clone();

    println!("start3\r\n");
    // Shared flag to stop the thread if the process dies
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();

    println!("start4\r\n");
    let watcher = thread::spawn(move || {
        println!("start5\r\n");
        let mut owned_env = OwnedEnv::new();
        let mut inotify = match Inotify::init() {
            Ok(i) => i,
            Err(_err) => {
                // tx.send(Err(format!("init failed: {:?}", err))).unwrap();
                let _ = tx.send(Err(init_failed()));

                // eprintln!("Failed to initialize inotify: {:?}", err);
                // return Err(error());
                return;
            }
        };

        println!("start6\r\n");
        if let Err(_err) = inotify.watches().add(&path, mask) {
            let _ = tx.send(Err(failed_to_add_watcher()));
            // Err(Error::BadArg);
            return;
            // return Err(error());
        }
        println!("start7\r\n");
        let _ = tx.send(Ok(ok()));

        let mut buffer = [0; 1024];
        while running_clone.load(Ordering::SeqCst) {
            println!(".\r");
            match inotify.read_events(&mut buffer) {
                Ok(events) => {
                    for event in events {
                        println!("start event\r\n");
                        let filename = event
                            .name
                            .and_then(|os_str| os_str.to_str().map(|s| s.to_string()))
                            .unwrap_or_else(|| "".to_string());

                        let mask_atoms = mask_to_atoms(event.mask);

                        let sent = OwnedEnv::send_and_clear(&mut owned_env, &pid, |env| {
                            println!("sent event\r\n");
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
                    std::thread::sleep(std::time::Duration::from_millis(100));
                    continue;
                }
                Err(_err) => {
                    println!("a");
                    let _ = tx.send(Err(inotify_error()));
                    break;
                }
            }
        }
    });

    // println!("start15\r\n");
    // match rx.recv() {
    //     Ok(_) => {
    //         let resource = ResourceArc::new(WatcherResource {
    //             inner: Mutex::new(WatcherResourceInner {
    //                 running,
    //                 watcher: Some(watcher),
    //                 down_called: false,
    //             }),
    //         });

    //         println!("start16\r\n");
    //         Ok((ok(), resource))
    //     }
    //     Err(err) => Ok(error(), err),
    // }

    match rx.recv() {
        Ok(Ok(_)) => {
            let resource = ResourceArc::new(WatcherResource {
                inner: Mutex::new(WatcherResourceInner {
                    running,
                    watcher: Some(watcher), // down_called: false,
                }),
            });

            println!("start16");
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
    println!("stop1");
    let mut inner = resource.inner.lock().unwrap();
    println!("stop2");
    // resource.running.store(false, Ordering::SeqCst);
    inner.running.store(false, Ordering::SeqCst);
    println!("stop3");

    if let Some(watcher) = inner.watcher.take() {
        println!("stop3.5");
        let _ = watcher.join();
    }
    println!("stop4");

    stopped()
}

// #[rustler::nif]
// fn on_down(resource: ResourceArc<WatcherResource>, _pid: LocalPid, _reason: Term) {
//     let mut inner = resource.inner.lock().unwrap();

//     if !inner.down_called {
//         eprintln!("[on_down] Elixir process died — stopping watcher thread.");
//         inner.running.store(false, Ordering::SeqCst);
//         inner.down_called = true;
//     }
// }

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
