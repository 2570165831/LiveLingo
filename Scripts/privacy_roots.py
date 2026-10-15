"""Shared private host-location grammar for text and readable binary paths."""


class PublicRegexSpelling(str):
    """A hash-bound source regex token, distinct from an approved UNC path."""


class PublicSourceSyntax(str):
    """An exact hash-bound upstream source statement, never a path prefix."""


PRIVATE_ROOTS = ("/" + "Users/", "/home/", "/Volumes/", "/private/var/", "/private/tmp/",
                 "/var/folders/", "/synthetic/", "/opt/homebrew/", "/usr/local/",
                 "/opt/local/", "/tmp/")
# Repeated separators include escaped source spellings. Full text metadata
# rejects every drive-rooted operand; binary bytes use distinctive home roots
# so instruction bytes and regex flags such as (?i:\b...) are not drive paths.
COMPILER_PATH_OPTIONS = ("-isystem", "-iquote", "-idirafter", "-iframework", "-isysroot",
                         "-include", "-imacros", "-I", "-L", "-F")
# A label such as prefix:/Users names a POSIX operand, not drive x:. Preserve
# that operand's offset/spelling. Backslashes identify the Windows spelling;
# forward-slash drives need a boundary or an explicit compiler option suffix.
_DRIVE_BOUNDARY = (r"(?:(?<![A-Za-z0-9_])|"
                   + "|".join("(?<=" + option + ")" for option in COMPILER_PATH_OPTIONS) + ")")
WINDOWS_HOME_PATTERN = (r"(?:[A-Za-z]:\\[\\/]*|" + _DRIVE_BOUNDARY
                        + r"[A-Za-z]:/[\\/]*)(?:Users|Documents and Settings)(?:[\\/]+|(?=$|\s))")
WINDOWS_UNC_PATTERN = (r"\\\\(?:[?.][\\/]+UNC[\\/]+)?"
                       r"[A-Za-z0-9][A-Za-z0-9._-]*[\\/]+"
                       r"[A-Za-z0-9_$][A-Za-z0-9_. $-]*(?:[\\/]+|(?=$|[\s\"'<>|;]))")
WINDOWS_PRIVATE_PATH_PATTERN = WINDOWS_HOME_PATTERN + "|" + WINDOWS_UNC_PATTERN
WINDOWS_PATH_PATTERN = r"[A-Za-z]:[\\/]+|" + WINDOWS_UNC_PATTERN
