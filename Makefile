all:
	$(MAKE) -C priv/src all

clean:
	$(MAKE) -C priv/src clean

.PHONY: all clean
