use flier_common::errno_atom;
use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, Resource, ResourceArc, Term};
use std::ffi::OsStr;
use std::fs::{self, DirEntry, ReadDir};
use std::os::unix::ffi::OsStrExt;
use std::sync::Mutex;

rustler::atoms! {
    closed,
    // Entry types
    file,
    directory,
    symlink,
    other,
    // Error reasons (OS errors are reported as errno atoms)
    already_closed,
    end_of_directory,
}

/// An open directory. An error hit after some entries of a batch were read
/// is kept in `pending_error` and returned by the next `readdir` call, so the
/// entries read before it are not lost.
struct DirState {
    read_dir: ReadDir,
    pending_error: Option<std::io::Error>,
}

/// Represents an open directory handle; `None` once closed.
struct DirResource {
    inner: Mutex<Option<DirState>>,
}

#[rustler::resource_impl]
impl Resource for DirResource {}

/// A directory entry with name, type, and relative path from the walk root.
/// The name is the raw bytes from the OS (Linux filenames need not be UTF-8).
#[derive(rustler::NifStruct)]
#[module = "Flier.Entries.Entry"]
struct Entry<'a> {
    name: Binary<'a>,
    r#type: Atom,
    path: Term<'a>,
}

/// Open a directory for reading. The path is taken as raw bytes so that
/// non-UTF-8 paths work. Returns `{:ok, ref}` or `{:error, errno}`.
#[rustler::nif(schedule = "DirtyIo")]
fn opendir(env: Env, path: Binary) -> Result<ResourceArc<DirResource>, Atom> {
    let read_dir =
        fs::read_dir(OsStr::from_bytes(path.as_slice())).map_err(|e| errno_atom(env, &e))?;

    Ok(ResourceArc::new(DirResource {
        inner: Mutex::new(Some(DirState {
            read_dir,
            pending_error: None,
        })),
    }))
}

/// Read up to `max` entries from the directory in one call, amortising the
/// cost of crossing into the NIF. Each entry's `:path` is set to `path`.
/// Returns `{:ok, entries}` with at least one entry, or `{:error, reason}`,
/// with reason `:end_of_directory` when exhausted. Raises `ArgumentError` if
/// `max` is 0.
#[rustler::nif(schedule = "DirtyIo")]
fn readdir<'a>(
    env: Env<'a>,
    resource: ResourceArc<DirResource>,
    max: usize,
    path: Term<'a>,
) -> NifResult<Result<Vec<Entry<'a>>, Atom>> {
    if max == 0 {
        return Err(Error::BadArg);
    }

    let mut guard = resource.inner.lock().unwrap();
    let Some(state) = guard.as_mut() else {
        return Ok(Err(already_closed()));
    };

    if let Some(err) = state.pending_error.take() {
        return Ok(Err(errno_atom(env, &err)));
    }

    let mut entries = Vec::new();
    while entries.len() < max {
        match state.read_dir.next() {
            Some(Ok(entry)) => entries.push(dir_entry_to_struct(env, &entry, path)),
            Some(Err(err)) if entries.is_empty() => return Ok(Err(errno_atom(env, &err))),
            Some(Err(err)) => {
                state.pending_error = Some(err);
                break;
            }
            None => break,
        }
    }

    if entries.is_empty() {
        Ok(Err(end_of_directory()))
    } else {
        Ok(Ok(entries))
    }
}

/// Close the directory handle
#[rustler::nif]
fn closedir(resource: ResourceArc<DirResource>) -> Atom {
    let mut guard = resource.inner.lock().unwrap();
    *guard = None;
    closed()
}

/// Convert a DirEntry to our Entry struct
fn dir_entry_to_struct<'a>(env: Env<'a>, entry: &DirEntry, path: Term<'a>) -> Entry<'a> {
    let file_name = entry.file_name();
    let bytes = file_name.as_bytes();
    let mut bin = OwnedBinary::new(bytes.len()).expect("failed to allocate OwnedBinary");
    bin.as_mut_slice().copy_from_slice(bytes);
    let name = bin.release(env);

    let type_ = match entry.file_type() {
        Ok(ft) if ft.is_file() => file(),
        Ok(ft) if ft.is_dir() => directory(),
        Ok(ft) if ft.is_symlink() => symlink(),
        _ => other(),
    };

    Entry {
        name,
        r#type: type_,
        path,
    }
}

rustler::init!("Elixir.Flier.Entries.Native");
