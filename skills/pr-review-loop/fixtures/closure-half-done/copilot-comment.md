`fetch` has no timeout, so a stalled server hangs every caller forever. Add a timeout parameter and pass it from each call site.
