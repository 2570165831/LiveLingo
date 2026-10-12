"""Shared private host-location grammar for text and readable binary paths."""

PRIVATE_ROOTS = ("/" + "Users/", "/home/", "/Volumes/", "/private/var/", "/private/tmp/",
                 "/var/folders/", "/synthetic/", "/opt/homebrew/", "/usr/local/",
                 "/opt/local/", "/tmp/")
# Repeated separators include escaped source spellings. Full text metadata
# rejects every drive-rooted operand; binary bytes use distinctive home roots
# so instruction bytes and regex flags such as (?i:\b...) are not drive paths.
WINDOWS_HOME_PATTERN = r"[A-Za-z]:[\\/]+(?:Users|Documents and Settings)(?:[\\/]+|(?=$|\s))"
WINDOWS_UNC_PATTERN = (r"\\\\(?:[?.][\\/]+UNC[\\/]+)?"
                       r"[A-Za-z0-9][A-Za-z0-9._-]*[\\/]+"
                       r"[A-Za-z0-9_$][A-Za-z0-9_. $-]*(?:[\\/]+|(?=$|[\s\"'<>|;]))")
WINDOWS_PRIVATE_PATH_PATTERN = WINDOWS_HOME_PATTERN + "|" + WINDOWS_UNC_PATTERN
WINDOWS_PATH_PATTERN = r"[A-Za-z]:[\\/]+|" + WINDOWS_UNC_PATTERN
