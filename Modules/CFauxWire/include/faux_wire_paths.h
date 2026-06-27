#ifndef FAUX_WIRE_PATHS_H
#define FAUX_WIRE_PATHS_H

/// Vends the string-concatenation socket-path macros from faux_wire.h, which the Swift importer cannot
/// surface directly, so the wire contract test can assert the Swift mirror against the C source of truth.
const char *faux_wire_socket_directory(void);
const char *faux_wire_auto_socket_path(void);

#endif
