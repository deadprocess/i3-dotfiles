CC      = gcc
CFLAGS  = -O2 -Wall -Wextra \
          $(shell pkg-config --cflags x11 xft xrandr)
LDFLAGS = $(shell pkg-config --libs x11 xft xrandr) -lpam

all: lockscreen

lockscreen: lockscreen.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: lockscreen
	install -Dm755 lockscreen /usr/local/bin/lockscreen

clean:
	rm -f lockscreen

.PHONY: all install clean
