`why`, `history` and `failures` read a `.gz` log that ends in zero bytes, as `gzip -d` does. Those bytes were read as another gzip member, and the log was refused.
