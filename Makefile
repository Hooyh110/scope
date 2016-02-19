.PHONY: all deps static clean client-lint client-test client-sync backend frontend shell lint

# If you can use Docker without being root, you can `make SUDO= <target>`
SUDO=$(shell (echo "$$DOCKER_HOST" | grep "tcp://" >/dev/null) || echo "sudo -E")
DOCKERHUB_USER=weaveworks
SCOPE_EXE=prog/scope
SCOPE_IMAGE=$(DOCKERHUB_USER)/scope
SCOPE_EXPORT=scope.tar
SCOPE_UI_BUILD_IMAGE=$(DOCKERHUB_USER)/scope-ui-build
SCOPE_UI_BUILD_UPTODATE=.scope_ui_build.uptodate
SCOPE_BACKEND_BUILD_IMAGE=$(DOCKERHUB_USER)/scope-backend-build
SCOPE_BACKEND_BUILD_UPTODATE=.scope_backend_build.uptodate
SCOPE_VERSION=$(shell git rev-parse --short HEAD)
DOCKER_VERSION=1.6.2
DOCKER_DISTRIB=.pkg/docker-$(DOCKER_VERSION).tgz
DOCKER_DISTRIB_URL=https://get.docker.com/builds/Linux/x86_64/docker-$(DOCKER_VERSION).tgz
RUNSVINIT=vendor/runsvinit/runsvinit
CODECGEN_DIR=vendor/github.com/ugorji/go/codec/codecgen
CODECGEN_EXE=$(CODECGEN_DIR)/codecgen
GET_CODECGEN_DEPS=$(shell find $(1) -maxdepth 1 -type f -name '*.go' -not -name '*_test.go' -not -name '*.codecgen.go' -not -name '*.generated.go')
CODECGEN_TARGETS=report/report.codecgen.go render/render.codecgen.go render/detailed/detailed.codecgen.go
RM=--rm
RUN_FLAGS=-ti
BUILD_IN_CONTAINER=true
GO ?= env GO15VENDOREXPERIMENT=1 go
GO_BUILD_INSTALL_DEPS=-i
GO_BUILD_TAGS=-tags netgo
GO_BUILD_FLAGS=$(GO_BUILD_INSTALL_DEPS) -ldflags "-extldflags \"-static\" -X main.version=$(SCOPE_VERSION)" $(GO_BUILD_TAGS)

all: $(SCOPE_EXPORT)

$(DOCKER_DISTRIB):
	curl -o $(DOCKER_DISTRIB) $(DOCKER_DISTRIB_URL)

docker/weave:
	curl -L git.io/weave -o docker/weave
	chmod u+x docker/weave

$(SCOPE_EXPORT): $(SCOPE_EXE) $(DOCKER_DISTRIB) docker/weave $(RUNSVINIT) docker/Dockerfile docker/run-app docker/run-probe docker/entrypoint.sh
	cp $(SCOPE_EXE) $(RUNSVINIT) docker/
	cp $(DOCKER_DISTRIB) docker/docker.tgz
	$(SUDO) docker build -t $(SCOPE_IMAGE) docker/
	$(SUDO) docker save $(SCOPE_IMAGE):latest > $@

$(RUNSVINIT): vendor/runsvinit/*.go

$(SCOPE_EXE): $(shell find ./ -path ./vendor -prune -o -type f -name *.go) prog/static.go


ifeq ($(BUILD_IN_CONTAINER),true)

$(SCOPE_EXE) $(RUNSVINIT) lint tests shell: $(SCOPE_BACKEND_BUILD_UPTODATE)
	@mkdir -p $(shell pwd)/.pkg
	$(SUDO) docker run $(RM) $(RUN_FLAGS) \
		-v $(shell pwd):/go/src/github.com/weaveworks/scope \
		-v $(shell pwd)/.pkg:/go/pkg \
		--net=host \
		-e GOARCH -e GOOS -e CIRCLECI -e CIRCLE_BUILD_NUM -e CIRCLE_NODE_TOTAL \
		-e CIRCLE_NODE_INDEX -e COVERDIR -e SLOW \
		$(SCOPE_BACKEND_BUILD_IMAGE) SCOPE_VERSION=$(SCOPE_VERSION) GO_BUILD_INSTALL_DEPS=$(GO_BUILD_INSTALL_DEPS) $@

else

$(SCOPE_EXE): $(SCOPE_BACKEND_BUILD_UPTODATE) $(CODECGEN_TARGETS)
	time $(GO) build $(GO_BUILD_FLAGS) -o $@ ./$(@D)
	@strings $@ | grep cgo_stub\\\.go >/dev/null || { \
	        rm $@; \
	        echo "\nYour go standard library was built without the 'netgo' build tag."; \
	        echo "To fix that, run"; \
	        echo "    sudo go clean -i net"; \
	        echo "    sudo go install -tags netgo std"; \
	        false; \
	    }

report/report.codecgen.go: $(call GET_CODECGEN_DEPS,report/)
render/render.codecgen.go: $(call GET_CODECGEN_DEPS,render/)
render/detailed/detailed.codecgen.go: $(call GET_CODECGEN_DEPS,render/detailed/)
%.codecgen.go: $(CODECGEN_EXE)
	cd $(@D) && env -u GOARCH -u GOOS $(shell pwd)/$(CODECGEN_EXE) -u -o $(@F) $(notdir $(filter-out $<,$^))

$(CODECGEN_EXE): $(CODECGEN_DIR)/*.go
	env -u GOARCH -u GOOS $(GO) build $(GO_BUILD_TAGS) -o $@ ./$(@D)

$(RUNSVINIT):
	time $(GO) build $(GO_BUILD_FLAGS) -o $@ ./$(@D)

shell:
	/bin/bash

tests:
	./tools/test -no-go-get

lint:
	./tools/lint .

endif

static: prog/static.go

ifeq ($(BUILD_IN_CONTAINER),true)
client/build/app.js: $(shell find client/app/scripts -type f) $(SCOPE_UI_BUILD_UPTODATE)
	mkdir -p client/build
	$(SUDO) docker run $(RM) $(RUN_FLAGS) -v $(shell pwd)/client/app:/home/weave/app \
		-v $(shell pwd)/client/build:/home/weave/build \
		$(SCOPE_UI_BUILD_IMAGE) npm run build

client-test: $(shell find client/app/scripts -type f) $(SCOPE_UI_BUILD_UPTODATE)
	$(SUDO) docker run $(RM) $(RUN_FLAGS) -v $(shell pwd)/client/app:/home/weave/app \
		-v $(shell pwd)/client/test:/home/weave/test \
		$(SCOPE_UI_BUILD_IMAGE) npm test

client-lint: $(SCOPE_UI_BUILD_UPTODATE)
	$(SUDO) docker run $(RM) $(RUN_FLAGS) -v $(shell pwd)/client/app:/home/weave/app \
		-v $(shell pwd)/client/test:/home/weave/test \
		$(SCOPE_UI_BUILD_IMAGE) npm run lint

client-start: $(SCOPE_UI_BUILD_UPTODATE)
	$(SUDO) docker run $(RM) $(RUN_FLAGS) --net=host -v $(shell pwd)/client/app:/home/weave/app \
		-v $(shell pwd)/client/build:/home/weave/build \
		$(SCOPE_UI_BUILD_IMAGE) npm start

prog/static.go: client/build/app.js $(SCOPE_BACKEND_BUILD_UPTODATE)
	$(SUDO) docker run $(RM) $(RUN_FLAGS) --net=host \
		-v $(shell pwd):/go/src/github.com/weaveworks/scope \
		-v $(shell pwd)/.pkg:/go/pkg \
		-w /go/src/github.com/weaveworks/scope \
		--entrypoint=make \
		$(SCOPE_BACKEND_BUILD_IMAGE) BUILD_IN_CONTAINER=false prog/static.go

else
client/build/app.js:
	cd client && npm run build

prog/static.go: client/build/app.js
	esc -o $@ -prefix client/build client/build
endif

$(SCOPE_UI_BUILD_UPTODATE): client/Dockerfile client/package.json client/webpack.local.config.js client/webpack.production.config.js client/server.js client/.eslintrc
	$(SUDO) docker build -t $(SCOPE_UI_BUILD_IMAGE) client
	touch $@

$(SCOPE_BACKEND_BUILD_UPTODATE): backend/*
	$(SUDO) docker build -t $(SCOPE_BACKEND_BUILD_IMAGE) backend
	touch $@

clean:
	$(GO) clean ./...
	$(SUDO) docker rmi $(SCOPE_UI_BUILD_IMAGE) $(SCOPE_BACKEND_BUILD_IMAGE) >/dev/null 2>&1 || true
	rm -rf $(SCOPE_EXPORT) $(SCOPE_UI_BUILD_UPTODATE) $(SCOPE_BACKEND_BUILD_UPTODATE) \
		$(SCOPE_EXE) $(RUNSVINIT) prog/static.go client/build/app.js docker/weave .pkg \
		$(CODECGEN_TARGETS) $(CODECGEN_EXE)

deps:
	$(GO) get -u -f $(GO_BUILD_TAGS) \
		github.com/FiloSottile/gvt \
		github.com/mattn/goveralls \
		github.com/weaveworks/github-release
