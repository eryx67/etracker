PROJECT := etracker
PROJECT_DIR := $(CURDIR)/apps/$(PROJECT)

ERL_FLAGS= -pa $(PROJECT_DIR)/.eunit -pa $(CURDIR)/apps/*/ebin \
	-pa $(CURDIR)/deps/*/ebin -setcookie $(PROJECT)

PROJECT_PLT=$(CURDIR)/.project_plt

ERL = $(shell which erl)

ifeq ($(ERL),)
$(error "Erlang not available on this system")
endif

REBAR=./rebar

comma := ,
comma_join = $(subst $(eval) ,$(comma),$(1))

ifeq ($(REBAR),)
$(error "Rebar not available on this system")
endif

.PHONY: all build compile doc clean test dialyzer typer shell distclean pdf \
	deps escript clean-common-test-data etop

all: build compile escript

build: deps compile
	$(REBAR) generate

deps:
	$(REBAR) get-deps
	$(REBAR) compile

compile: app-src
	$(REBAR) skip_deps=true compile

escript: compile
	$(REBAR) skip_deps=true escriptize

doc:
	$(REBAR) skip_deps=true doc

eunit: compile clean-common-test-data
	ERL_FLAGS="$(ERL_FLAGS) -config test.config" $(REBAR) skip_deps=true eunit

ct: compile clean-common-test-data
	$(REBAR) skip_deps=true ct

test: compile eunit ct

tags:
	@ctags -e -R -f TAGS apps deps

$(PROJECT_PLT):
	@echo Building local plt at $(PROJECT_PLT)
	@echo
	dialyzer --output_plt $(PROJECT_PLT) --build_plt \
	--apps erts kernel stdlib -r deps

dialyzer: $(PROJECT_PLT)
	dialyzer --plt $(PROJECT_PLT) --fullpath -Wrace_conditions \
	-I include -pa $(CURDIR)/ebin --src $(PROJECT_DIR)/src

typer:
	typer --plt $(PROJECT_PLT) -r $(PROJECT_DIR)/src

app-src: $(PROJECT_DIR)/src/*.erl
app-src: override MODULES = $(call comma_join,$(basename $(^F)))
app-src:
	sed -i 's/{modules, \[[a-zA-Z0-9_,]*\]}/{modules, \[$(MODULES)\]}/' \
		$(PROJECT_DIR)/src/$(PROJECT).app.src

shell: deps compile
	- mkdir -p $(CURDIR)/data
	- @$(REBAR) skip_deps=true eunit
	/usr/bin/env ERL_MAX_PORTS=128000 $(ERL) -name $(PROJECT)@127.0.0.1 $(ERL_FLAGS) \
	+K true +A 32 \
	-boot start_sasl -config $(PROJECT).config

etop:
		erl -name etop@127.0.0.1 -hidden -s etop -s erlang halt -output text \
		-node $(PROJECT)@127.0.0.1 -setcookie $(PROJECT) -tracing off

pdf:
	pandoc README.md -o README.pdf

clean-common-test-data:
	- rm -rf $(CURDIR)/test/*_SUITE_data

clean: clean-common-test-data
	- rm -rf $(CURDIR)/data
	- rm -rf $(CURDIR)/test/*.beam
	- rm -rf $(CURDIR)/log
	$(REBAR) skip_deps=true clean

distclean: clean
	- rm -f $(CURDIR)/TAGS
	- rm -rf $(PROJECT_PLT)
	- rm -rvf $(CURDIR)/deps/*
