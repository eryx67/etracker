ERL_FLAGS= -pa $(CURDIR)/.eunit -pa $(CURDIR)/ebin -pa $(CURDIR)/deps/*/ebin

PROJECT_PLT=$(CURDIR)/.project_plt

ERL = $(shell which erl)

ifeq ($(ERL),)
$(error "Erlang not available on this system")
endif

REBAR=./rebar

ifeq ($(REBAR),)
$(error "Rebar not available on this system")
endif

.PHONY: all build compile doc clean test dialyzer typer shell distclean pdf \
	deps escript clean-common-test-data

all: build compile escript

build: deps compile
	$(REBAR) generate

deps:
	$(REBAR) get-deps
	$(REBAR) compile

compile:
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
	-I include -pa $(CURDIR)/ebin --src apps/etracker/src

typer:
	typer --plt $(PROJECT_PLT) -r ./apps/etracker/src

shell: deps compile
	- mkdir -p $(CURDIR)/data
	- @$(REBAR) skip_deps=true eunit
	@$(ERL) $(ERL_FLAGS) -boot start_sasl -config etracker.config

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
