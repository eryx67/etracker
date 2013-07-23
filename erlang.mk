ifeq ($(PROJECT),)
$(error "Please set PROJECT variable in your Makefile")
endif

ifeq ($(PROJECT_TYPE),)
$(warning "PROJECT_TYPE is not defined, set to 'application'")
PROJECT_TYPE = application
endif

ifeq ($(PROJECT_DIR),)
PROJECT_DIR := $(CURDIR)
endif

ifeq ($(NODE),)
NODE := $(PROJECT)@127.0.0.1
endif

ifeq ($(NODE_COOKIE),)
NODE_COOKIE := $(PROJECT)
endif

# ERL_FLAGS= -pa $(PROJECT_DIR)/.eunit -pa $(PROJECT_DIR)/ebin \
# 	-pa $(CURDIR)/deps/*/ebin -setcookie $(PROJECT)

ERL_FLAGS= -pa $(PROJECT_DIR)/.eunit -pa $(PROJECT_DIR)/ebin \
	-pa $(CURDIR)/deps/*/ebin

PROJECT_PLT=$(CURDIR)/.project_plt

ERL = $(shell which erl)

ifeq ($(ERL),)
$(error "Erlang not available on this system")
endif

REBAR=./rebar

comma := ,
comma_join = $(subst $(eval) ,$(comma),$(1))
when_project_app = $(and $(filter app%, $(PROJECT_TYPE)), $(1))
when_project_rel = $(and $(filter rel% node%, $(PROJECT_TYPE)), $(1))

ifeq ($(REBAR),)
$(error "Rebar not available on this system")
endif

.PHONY: all build compile doc clean test dialyzer typer shell distclean pdf \
	deps escript clean-common-test-data etop

all: deps compile $(call  when_project_rel,build) $(call  when_project_app,escript)

build: deps compile
	$(REBAR) generate

deps:
	$(REBAR) get-deps
	$(REBAR) compile

update-deps:
	$(REBAR) update-deps; \
	for dir in $(dir $(wildcard deps/*/.git)); do \
		pushd `pwd`; \
		echo Pulling in $$dir; \
		cd $$dir; \
		git pull; \
		git checkout; \
		popd; \
	done

compile: $(call when_project_app,app-src)
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
	@ctags -e -R -f TAGS apps deps src

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
	$(ERL) -name $(NODE) -setcookie $(NODE_COOKIE) $(ERL_FLAGS) \
	+K true +A 256 +P 512000  +Q 128000 \
	-boot start_sasl -config $(PROJECT).config

etop:
		erl +d -name etop@127.0.0.1 -hidden -s etop -s erlang halt -output text \
		-node $(NODE) -setcookie $(NODE_COOKIE) -tracing off

entop:
		erl -hidden -noinput $(ERL_FLAGS) +d +A 20 -name entop@127.0.0.1 \
		-eval "entop:start('$(NODE)')" -setcookie $(NODE_COOKIE)

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
