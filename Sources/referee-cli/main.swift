import Foundation

// Wave 0a placeholder (plan.md section 11.4, WP0a): the target exists so that the package and its two products are
// complete. WP0b adds `dump-raw`; Gate 1 writes the eight subcommands of section 10.2.

FileHandle.standardError.write(Data("referee-cli: no subcommand is implemented in this build yet (plan.md section 10.2).\n".utf8))
exit(2)
