PROGNAME := etracker
QL_DIR := $(CURDIR)/quicklisp
QLASDF_DIR := $(QL_DIR)/dists/quicklisp/software
BUILDAPP_DIR := $(CURDIR)/buildapp

DEPS := $(wildcard *.asd *.lisp)

define lisp_eval
	sbcl --no-userinit $(patsubst @%,--eval %,$(1)) --eval "(quit)"
endef

all : $(PROGNAME)

clean : quicklisp-clean buildapp-clean
	rm -f $(PROGNAME)

$(PROGNAME) : quicklisp buildapp $(DEPS)
	sbcl --no-userinit --script load-deps.lisp
	./bin/buildapp --output $(PROGNAME) --asdf-path . --asdf-tree $(QLASDF_DIR) \
					--load-system munin --entry munin:main --compress-core

quicklisp : quicklisp/quicklisp.lisp
	$(call lisp_eval, @'(load "$<")' \
					@'(quicklisp-quickstart:install :path #p"$(QL_DIR)/")')

quicklisp-clean :
	rm -rf quicklisp

quicklisp/quicklisp.lisp :
	mkdir -p quicklisp
	wget -O $@ http://beta.quicklisp.org/quicklisp.lisp

buildapp : bin/buildapp

buildapp-clean:
	rm -f bin/buildapp

bin/buildapp :
	mkdir -p bin
	$(call lisp_eval, @"(require 'asdf)" \
						@"(asdf:initialize-source-registry \
							'(:source-registry (:directory #p\"$(BUILDAPP_DIR)/\") \
							:inherit-configuration))" \
						@"(require 'buildapp)" \
						@"(buildapp::build-buildapp \"$@\")")
