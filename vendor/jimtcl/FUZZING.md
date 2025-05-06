# Fuzzing

Be sure to only fuzz on a computer/VM that you can lose work on! Jimtcl has access to multiple types of I/O--I've already had the fuzzer fill a directory with crap.

To setup:
1. Make sure you have `afl++` installed.
2. Set permissions with `chmod +x setup-fuzzing.sh start-fuzzing.sh`
3. Run `./setup-fuzzing.sh` (will ./configure and make)
4. Start fuzzing with `./start-fuzzing.sh` (I'd suggest running it in something like GNU screen so you can detach and reattach)
5. Profit!