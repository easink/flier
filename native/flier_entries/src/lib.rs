use rustler::{Atom, Encoder, Env, NifResult, Resource, ResourceArc};
use std::fs::{self, DirEntry, ReadDir};
use std::sync::Mutex;

rustler::atoms! {
    ok,
    error,
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

/// A directory entry with name and type
#[derive(rustler::NifStruct)]
#[module = "Flier.Entries.Entry"]
struct Entry {
    name: String,
    r#type: Atom,
}

/// Result type for opendir - either success with resource or error with reason
enum OpendirResult {
    Ok(ResourceArc<DirResource>),
    Error(Atom),
}

impl Encoder for OpendirResult {
    fn encode<'a>(&self, env: Env<'a>) -> rustler::Term<'a> {
        match self {
            OpendirResult::Ok(resource) => (ok(), resource).encode(env),
            OpendirResult::Error(reason) => (error(), *reason).encode(env),
        }
    }
}

/// Open a directory for reading
#[rustler::nif(schedule = "DirtyIo")]
fn opendir(path: String) -> OpendirResult {
    match fs::read_dir(&path) {
        Ok(read_dir) => {
            let resource = ResourceArc::new(DirResource {
                inner: Mutex::new(Some(read_dir)),
            });
            OpendirResult::Ok(resource)
        }
        Err(err) => {
            let reason = io_error_to_atom(&err);
            OpendirResult::Error(reason)
        }
    }
}

/// Read the next entry from the directory
#[rustler::nif(schedule = "DirtyIo")]
fn readdir(env: Env, resource: ResourceArc<DirResource>) -> NifResult<rustler::Term> {
    let mut guard = resource.inner.lock().unwrap();

    match guard.as_mut() {
        None => {
            // Directory was already closed
            Ok((error(), already_closed()).encode(env))
        }
        Some(read_dir) => {
            match read_dir.next() {
                Some(Ok(entry)) => {
                    let entry_struct = dir_entry_to_struct(&entry);
                    Ok((ok(), entry_struct).encode(env))
                }
                Some(Err(err)) => {
                    let reason = io_error_to_atom(&err);
                    Ok((error(), reason).encode(env))
                }
                None => {
                    // End of directory
                    Ok((error(), end_of_directory()).encode(env))
                }
            }
        }
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
fn dir_entry_to_struct(entry: &DirEntry) -> Entry {
    let name = entry.file_name().to_string_lossy().into_owned();

    let type_ = match entry.file_type() {
        Ok(ft) if ft.is_file() => file(),
        Ok(ft) if ft.is_dir() => directory(),
        Ok(ft) if ft.is_symlink() => symlink(),
        _ => other(),
    };

    Entry {
        name,
        r#type: type_,
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
