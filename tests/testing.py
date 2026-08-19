import collections
import fnmatch
import io
import os
import pathlib
import queue
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.request
from contextlib import redirect_stdout

CYAN_COLOR = "\033[36m"
GRAY_COLOR = "\033[2m"
RED_COLOR = "\033[31m"
GREEN_COLOR = "\033[32m"
RESET_COLOR = "\033[0m"
WHITE_BOLD = "\033[1m"

MAX_TIMEOUT = 60 * 5

PATH = pathlib.Path(__file__).parent.resolve()


class Valgrind:
    @staticmethod
    def get_valgrind_command(expect_failure=False):
        if expect_failure:
            return [
                "valgrind",
                "--error-exitcode=42",
                "--leak-check=no",
            ]

        return [
            "valgrind",
            "--error-exitcode=42",
            "--errors-for-leak-kinds=all",
            "--leak-check=full",
        ]

    @staticmethod
    def get_valgrind_thread_command():
        return ["valgrind", "--error-exitcode=42", "--fair-sched=try"]


class EPD:
    @staticmethod
    def create_bench_epd():
        with open(f"{os.path.join(PATH, 'bench_tmp.epd')}", "w") as f:
            f.write(
                """
Rn6/1rbq1bk1/2p2n1p/2Bp1p2/3Pp1pP/1N2P1P1/2Q1NPB1/6K1 w - - 2 26
rnbqkb1r/ppp1pp2/5n1p/3p2p1/P2PP3/5P2/1PP3PP/RNBQKBNR w KQkq - 0 3
3qnrk1/4bp1p/1p2p1pP/p2bN3/1P1P1B2/P2BQ3/5PP1/4R1K1 w - - 9 28
r4rk1/1b2ppbp/pq4pn/2pp1PB1/1p2P3/1P1P1NN1/1PP3PP/R2Q1RK1 w - - 0 13
"""
            )

    @staticmethod
    def delete_bench_epd():
        os.remove(f"{os.path.join(PATH, 'bench_tmp.epd')}")


class Syzygy:
    @staticmethod
    def get_syzygy_path():
        return os.path.abspath("syzygy")

    @staticmethod
    def download_syzygy():
        if not os.path.isdir(os.path.join(PATH, "syzygy")):
            url = "https://api.github.com/repos/niklasf/python-chess/tarball/9b9aa13f9f36d08aadfabff872882f4ab1494e95"
            file = "niklasf-python-chess-9b9aa13"

            with tempfile.TemporaryDirectory() as tmpdirname:
                tarball_path = os.path.join(tmpdirname, f"{file}.tar.gz")

                # urllib, not requests: this was the module's ONLY use of a
                # third-party import, and the whole file dies at import time
                # without it -- so a gate that merely imports this harness
                # reported ModuleNotFoundError instead of a verdict, and two CI
                # lanes carried a pip install to paper over it. copyfileobj does
                # the chunked copy in C rather than a Python loop.
                #
                # urlopen raises on a non-2xx, so no separate status check is
                # needed here. An error body written to the file instead would
                # surface two statements later as "tarfile.ReadError: not a gzip
                # file", naming the wrong thing.
                #
                # The API also wants a User-Agent and answers 403 without one;
                # requests sent its own, urllib's default is thinner, so it is set
                # here rather than left to the library.
                request = urllib.request.Request(
                    url,
                    headers={
                        "User-Agent": "stockfish-tests",
                        "Accept": "application/vnd.github+json",
                    },
                )
                # Retry the transient statuses. GitHub answers 429 under a rate
                # limit and 502/503/504 when its API is briefly unwell, and one
                # of those took out two CI lanes that had nothing to do with
                # the network: the whole job fails on a gateway timeout that a
                # second attempt would have survived. A 4xx that is not 429 is
                # a permanent answer and is raised on the first try, because
                # retrying a 404 only delays the report.
                transient = {429, 500, 502, 503, 504}
                for attempt in range(5):
                    try:
                        with (
                            urllib.request.urlopen(request) as response,
                            open(tarball_path, "wb") as f,
                        ):
                            shutil.copyfileobj(response, f)
                        break
                    except urllib.error.HTTPError as e:
                        if e.code not in transient or attempt == 4:
                            raise
                        reason = f"HTTP {e.code}"
                    except urllib.error.URLError as e:
                        if attempt == 4:
                            raise
                        reason = f"{e.reason}"
                    delay = 2**attempt
                    print(
                        f"syzygy: {reason} from {url}, retrying in {delay}s ({attempt + 1}/4)",
                        file=sys.stderr,
                    )
                    time.sleep(delay)

                # Check the magic before untarring. A truncated or substituted body
                # is a download problem, and saying so beats a decompression error
                # for a reader deciding whether the network or the corpus is at
                # fault.
                with open(tarball_path, "rb") as f:
                    if f.read(2) != b"\x1f\x8b":
                        raise RuntimeError(
                            f"{url} did not return a gzip archive; the download failed"
                        )

                with tarfile.open(tarball_path, "r:gz") as tar:
                    tar.extractall(tmpdirname)

                shutil.move(os.path.join(tmpdirname, file), os.path.join(PATH, "syzygy"))


class OrderedClassMembers(type):
    @classmethod
    def __prepare__(self, name, bases):
        return collections.OrderedDict()

    def __new__(self, name, bases, classdict):
        classdict["__ordered__"] = [
            key for key in classdict if key not in ("__module__", "__qualname__")
        ]
        return type.__new__(self, name, bases, classdict)


class TimeoutException(Exception):
    def __init__(self, message: str, timeout: float):
        super().__init__(message)
        self.message = message
        self.timeout = timeout


class UnexpectedOutputException(Exception):
    def __init__(self, actual: str, expected: str):
        self.actual = actual
        self.expected = expected


class MiniTestFramework:
    def __init__(self):
        self.passed_test_suites = 0
        self.failed_test_suites = 0
        self.passed_tests = 0
        self.failed_tests = 0
        self.stop_on_failure = True

    def has_failed(self) -> bool:
        return self.failed_test_suites > 0

    def run(self, classes: list[type]) -> bool:
        self.start_time = time.time()

        for test_class in classes:
            with tempfile.TemporaryDirectory() as tmpdirname:
                original_cwd = os.getcwd()
                os.chdir(tmpdirname)

                try:
                    if self.__run(test_class):
                        self.failed_test_suites += 1
                    else:
                        self.passed_test_suites += 1
                except Exception as e:
                    self.failed_test_suites += 1
                    print(f"\n{RED_COLOR}Error: {e}{RESET_COLOR}")
                finally:
                    os.chdir(original_cwd)

        self.__print_summary(round(time.time() - self.start_time, 2))
        return self.has_failed()

    def __run(self, test_class) -> bool:
        test_instance = test_class()
        test_name = test_instance.__class__.__name__
        test_methods = [m for m in test_instance.__ordered__ if m.startswith("test_")]

        print(f"\nTest Suite: {test_name}")

        if hasattr(test_instance, "beforeAll"):
            test_instance.beforeAll()

        fails = 0

        for method in test_methods:
            fails += self.__run_test_method(test_instance, method)

        if hasattr(test_instance, "afterAll"):
            test_instance.afterAll()

        self.failed_tests += fails

        return fails > 0

    def __run_test_method(self, test_instance, method: str) -> int:
        print(f"    Running {method}... \r", end="", flush=True)

        buffer = io.StringIO()
        fails = 0
        failed = False

        try:
            t0 = time.time()

            with redirect_stdout(buffer):
                if hasattr(test_instance, "beforeEach"):
                    test_instance.beforeEach()

                getattr(test_instance, method)()

                if hasattr(test_instance, "afterEach"):
                    test_instance.afterEach()

            duration = time.time() - t0

            self.print_success(f" {method} ({duration * 1000:.2f}ms)")
            self.passed_tests += 1
        except Exception as e:
            failed = True

            if isinstance(e, TimeoutException):
                self.print_failure(f" {method} (hit execution limit of {e.timeout} seconds)")

            if isinstance(e, UnexpectedOutputException):
                self.print_failure(
                    f' {method} encountered unexpected output: "{e.actual}" when output matching "{e.expected}" was expected'
                )

            if isinstance(e, AssertionError):
                self.__handle_assertion_error(t0, method)

            if self.stop_on_failure:
                raise e

            fails += 1
        finally:
            if failed:
                self.__print_buffer_output(buffer)

        return fails

    def __handle_assertion_error(self, start_time, method: str):
        duration = time.time() - start_time
        self.print_failure(f" {method} ({duration * 1000:.2f}ms)")
        traceback_output = "".join(traceback.format_tb(sys.exc_info()[2]))

        colored_traceback = "\n".join(
            f"  {CYAN_COLOR}{line}{RESET_COLOR}" for line in traceback_output.splitlines()
        )

        print(colored_traceback)

    def __print_buffer_output(self, buffer: io.StringIO):
        output = buffer.getvalue()
        if output:
            indented_output = "\n".join(f"    {line}" for line in output.splitlines())
            print(f"    {RED_COLOR}⎯⎯⎯⎯⎯OUTPUT⎯⎯⎯⎯⎯{RESET_COLOR}")
            print(f"{GRAY_COLOR}{indented_output}{RESET_COLOR}")
            print(f"    {RED_COLOR}⎯⎯⎯⎯⎯OUTPUT⎯⎯⎯⎯⎯{RESET_COLOR}")

    def __print_summary(self, duration: float):
        print(f"\n{WHITE_BOLD}Test Summary{RESET_COLOR}\n")
        print(
            f"    Test Suites: {GREEN_COLOR}{self.passed_test_suites} passed{RESET_COLOR}, {RED_COLOR}{self.failed_test_suites} failed{RESET_COLOR}, {self.passed_test_suites + self.failed_test_suites} total"
        )
        print(
            f"    Tests:       {GREEN_COLOR}{self.passed_tests} passed{RESET_COLOR}, {RED_COLOR}{self.failed_tests} failed{RESET_COLOR}, {self.passed_tests + self.failed_tests} total"
        )
        print(f"    Time:        {duration}s\n")

    def print_failure(self, add: str):
        print(f"    {RED_COLOR}✗{RESET_COLOR}{add}", flush=True)

    def print_success(self, add: str):
        print(f"    {GREEN_COLOR}✓{RESET_COLOR}{add}", flush=True)


class Stockfish:
    def __init__(
        self,
        prefix: list[str],
        path: str,
        args: list[str] | None = None,
        cli: bool = False,
        expect_failure: bool = False,
    ):
        if args is None:
            args = []
        self.path = path
        self.process = None
        self.args = args
        self.cli = cli
        self.expect_failure = expect_failure
        self.prefix = prefix
        self.output = []
        self.output_queue = queue.Queue()
        self.reader_thread = None

        self.start()

    def _check_process_alive(self):
        if not self.process or self.process.poll() is not None:
            print("\n".join(self.output))
            raise RuntimeError("Stockfish process has terminated")

    def start(self):
        if self.cli:
            self.process = subprocess.run(
                [*self.prefix, self.path, *self.args],
                capture_output=True,
                text=True,
            )

            if self.process.stdout:
                self.output.extend(self.process.stdout.splitlines())
            if self.process.stderr:
                self.output.extend(self.process.stderr.splitlines())

            if self.process.returncode != 0:
                print(self.process.stdout)
                print(self.process.stderr)
                print(f"Process failed with return code {self.process.returncode}")

            return

        self.process = subprocess.Popen(
            [*self.prefix, self.path, *self.args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            bufsize=1,
        )
        self.reader_thread = threading.Thread(target=self._read_process_output, daemon=True)
        self.reader_thread.start()

    def _read_process_output(self):
        try:
            for line in self.process.stdout:
                line = line.strip()
                self.output.append(line)
                self.output_queue.put(line)
        except (OSError, ValueError):
            pass
        finally:
            self.output_queue.put(None)

    def setoption(self, name: str, value: str):
        self.send_command(f"setoption name {name} value {value}")

    def send_command(self, command: str):
        if not self.process:
            raise RuntimeError("Stockfish process is not started")

        self._check_process_alive()

        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

    def equals(self, expected_output: str):
        for line in self.readline():
            if line == expected_output:
                return

    def expect(self, expected_output: str):
        for line in self.readline():
            if fnmatch.fnmatch(line, expected_output):
                return

    def contains(self, expected_output: str):
        for line in self.readline():
            if expected_output in line:
                return

    def starts_with(self, expected_output: str):
        for line in self.readline():
            if line.startswith(expected_output):
                return

    def check_output(self, callback):
        if not callback:
            raise ValueError("Callback function is required")

        for line in self.readline():
            if callback(line):
                return

    def expect_for_line_matching(self, line_match: str, expected: str):
        for line in self.readline():
            if fnmatch.fnmatch(line, line_match):
                if fnmatch.fnmatch(line, expected):
                    break
                else:
                    raise UnexpectedOutputException(line, expected)

    def readline(self, timeout: float = MAX_TIMEOUT):
        if not self.process:
            raise RuntimeError("Stockfish process is not started")

        deadline = time.monotonic() + timeout

        while True:
            self._check_process_alive()

            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0:
                raise TimeoutException(
                    f"No matching output received after {timeout} seconds",
                    timeout,
                )

            try:
                line = self.output_queue.get(timeout=remaining_time)
            except queue.Empty:
                raise TimeoutException(
                    f"No matching output received after {timeout} seconds",
                    timeout,
                ) from None

            if line is None:
                self._check_process_alive()
                raise RuntimeError("Stockfish process has terminated")

            yield line

    def clear_output(self):
        self.output = []

    def get_output(self) -> list[str]:
        return self.output

    def quit(self):
        self.send_command("quit")

    def close(self):
        if self.process:
            self.process.stdin.close()
            self.process.stdout.close()
            return self.process.wait()

        return 0
