//! Helpers shared by the Flier NIF crates.

use rustler::{Atom, Env};

/// errno values and the atom names Erlang's `:file` module uses for them.
const ERRNO_NAMES: [(i32, &str); 22] = [
    (libc::EPERM, "eperm"),
    (libc::ENOENT, "enoent"),
    (libc::EIO, "eio"),
    (libc::EBADF, "ebadf"),
    (libc::ENOMEM, "enomem"),
    (libc::EACCES, "eacces"),
    (libc::EFAULT, "efault"),
    (libc::EBUSY, "ebusy"),
    (libc::EEXIST, "eexist"),
    (libc::ENODEV, "enodev"),
    (libc::ENOTDIR, "enotdir"),
    (libc::EISDIR, "eisdir"),
    (libc::EINVAL, "einval"),
    (libc::ENFILE, "enfile"),
    (libc::EMFILE, "emfile"),
    (libc::ENOSPC, "enospc"),
    (libc::EROFS, "erofs"),
    (libc::ENAMETOOLONG, "enametoolong"),
    (libc::ELOOP, "eloop"),
    (libc::EOVERFLOW, "eoverflow"),
    (libc::ESTALE, "estale"),
    (libc::ENOSYS, "enosys"),
];

/// Convert an I/O error to a POSIX errno atom such as `:enoent` or `:eacces`,
/// matching the reasons returned by Erlang's `:file` and Elixir's `File`.
/// Errors without a known errno become `:unknown`.
pub fn errno_atom(env: Env, err: &std::io::Error) -> Atom {
    let name = err
        .raw_os_error()
        .and_then(|code| ERRNO_NAMES.iter().find(|(c, _)| *c == code))
        .map_or("unknown", |(_, name)| name);

    Atom::from_str(env, name).expect("errno names are valid atoms")
}
