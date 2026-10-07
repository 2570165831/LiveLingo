"""Argument parsing with fixed diagnostics and an explicitly supplied program name."""
import argparse


class PrivateArgumentParser(argparse.ArgumentParser):
    """Never print a parse failure's message or derive prog from sensitive argv[0].

    Normal argparse values, help and subparsers are preserved. Subparsers inherit
    this class and a program name derived from the parent's explicit name.
    """

    def __init__(self, *, prog: str, **kwargs):
        if not isinstance(prog, str) or not prog:
            raise ValueError("an explicit nonempty program name is required")
        super().__init__(prog=prog, **kwargs)

    def error(self, message):
        # Unknown flags, values, choices and converter exception text can all
        # contain private content. Do not try to recognize or redact that text.
        super().error("invalid_arguments; use --help for usage.")

    def parse_known_args(self, args=None, namespace=None):
        try:
            return super().parse_known_args(args, namespace)
        except argparse.ArgumentError:
            # exit_on_error=False otherwise lets a caller print the raw error.
            self.error(None)
