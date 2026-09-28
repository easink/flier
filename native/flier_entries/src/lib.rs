use rustler::{Atom, Binary, Env, OwnedBinary, Resource, ResourceArc};
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
    // Error reasons
    not_found,
    permission_denied,
    not_a_directory,
    io_error,
    already_closed,
    end_of_directory,
}

/// Represents an open directory handle
struct DirResource {
    inner: Mutex<Option<ReadDir>>,
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
    path: String,
}

/// Open a directory for reading. The path is taken as raw bytes so that
/// non-UTF-8 paths work. Returns `{:ok, ref}` or `{:error, reason}`.
#[rustler::nif(schedule = "DirtyIo")]
fn opendir(path: Binary) -> Result<ResourceArc<DirResource>, Atom> {
    let read_dir =
        fs::read_dir(OsStr::from_bytes(path.as_slice())).map_err(|e| io_error_to_atom(&e))?;

    Ok(ResourceArc::new(DirResource {
        inner: Mutex::new(Some(read_dir)),
    }))
}

/// Read the next entry from the directory. Returns `{:ok, entry}` or
/// `{:error, reason}`, with reason `:end_of_directory` when exhausted.
#[rustler::nif(schedule = "DirtyIo")]
fn readdir(env: Env, resource: ResourceArc<DirResource>) -> Result<Entry, Atom> {
    let mut guard = resource.inner.lock().unwrap();
    let read_dir = guard.as_mut().ok_or_else(already_closed)?;

    match read_dir.next() {
        Some(Ok(entry)) => Ok(dir_entry_to_struct(env, &entry)),
        Some(Err(err)) => Err(io_error_to_atom(&err)),
        None => Err(end_of_directory()),
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
fn dir_entry_to_struct<'a>(env: Env<'a>, entry: &DirEntry) -> Entry<'a> {
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
        path: ".".to_string(),
    }
}

/// Convert std::io::Error to an atom
fn io_error_to_atom(err: &std::io::Error) -> Atom {
    use std::io::ErrorKind;

    match err.kind() {
        ErrorKind::NotFound => not_found(),
        ErrorKind::PermissionDenied => permission_denied(),
        ErrorKind::NotADirectory => not_a_directory(),
        _ => io_error(),
    }
}

rustler::init!("Elixir.Flier.Entries.Native");
