# khan
# https://github.com/topfreegames/khan
# Licensed under the MIT license:
# http://www.opensource.org/licenses/mit-license
# Copyright © 2016 Top Free Games <backend@tfgco.com>

PACKAGES = $(shell glide novendor)
GODIRS = $(shell go list ./... | grep -v /vendor/ | sed s@github.com/topfreegames/khan@.@g | egrep -v "^[.]$$")
PMD = "pmd-bin-5.3.3"
OS = "$(shell uname | awk '{ print tolower($$0) }')"

setup:
	@go get -u github.com/Masterminds/glide/...
	@go get -v github.com/spf13/cobra/cobra
	@go get github.com/fzipp/gocyclo
	@go get github.com/topfreegames/goose/cmd/goose
	@go get github.com/fzipp/gocyclo
	@go get github.com/gordonklaus/ineffassign
	@go get -u github.com/jteeuwen/go-bindata/...
	@glide install

setup-docs:
	@pip install -q --log /tmp/pip.log --no-cache-dir sphinx recommonmark sphinx_rtd_theme

setup-ci:
	@go get -u github.com/Masterminds/glide/...
	@go get -u github.com/jteeuwen/go-bindata/...
	@go get github.com/topfreegames/goose/cmd/goose
	@go get github.com/mattn/goveralls
	@go get github.com/onsi/ginkgo/ginkgo
	@glide install

build:
	@go build $(PACKAGES)
	@go build

assets:
	@for pkg in $(GODIRS) ; do \
		go generate -x $$pkg ; \
    done

start-deps:
	@cd ./scripts && docker-compose --project-name=khan up -d
	@until docker exec khan_postgres_1 pg_isready; do echo 'Waiting for Postgres...' && sleep 1; done
	@until docker exec khan_elasticsearch_1 curl localhost:9200; do echo 'Waiting for Elasticsearch...' && sleep 1; done
	@sleep 5
	@docker exec khan_postgres_1 createuser -s -U postgres khan; true
	@docker exec khan_postgres_1 createdb -U khan khan; true
	@make migrate

stop-deps:
	@cd ./scripts && docker-compose --project-name=khan down

cross: assets
	@mkdir -p ./bin
	@echo "Building for linux-i386..."
	@env GOOS=linux GOARCH=386 go build -o ./bin/khan-linux-i386
	@echo "Building for linux-x86_64..."
	@env GOOS=linux GOARCH=amd64 go build -o ./bin/khan-linux-x86_64
	@echo "Building for darwin-i386..."
	@env GOOS=darwin GOARCH=386 go build -o ./bin/khan-darwin-i386
	@echo "Building for darwin-x86_64..."
	@env GOOS=darwin GOARCH=amd64 go build -o ./bin/khan-darwin-x86_64
	@chmod +x bin/*

install:
	@go install

run:
	@go run main.go start -d -v3 -c ./config/local.yaml

build-docker:
	@docker build -t khan .

build-dev-docker:
	@cp ./config/default.yaml ./dev
	@cp ./bin/khan-linux-x86_64 ./dev
	@cd dev && docker build -t khan-dev .

# the crypto
run-docker:
	@docker run -i -t --rm \
		-e "KHAN_POSTGRES_HOST=`ifconfig | egrep inet | egrep -v inet6 | egrep -v 127.0.0.1 | awk ' { print $$2 } '`" \
		-e "SERVER_NAME=localhost" \
		-e "AUTH_USERNAME=auth-username" \
		-e "AUTH_PASSWORD=auth-password" \
		-p 8080:80 \
		khan

test: start-deps assets drop-test db-test drop-es-test
	@ginkgo --cover $(GODIRS)

drop-es-test:
	@curl -X DELETE localhost:9200/khan*

test-coverage coverage: test
	@echo "mode: count" > coverage-all.out
	@bash -c 'for f in $$(find . -name "*.coverprofile"); do tail -n +2 $$f >> coverage-all.out; done'

test-coverage-html coverage-html: test-coverage
	@go tool cover -html=coverage-all.out

db migrate:
	@go run main.go migrate -c ./config/local.yaml

random-data:
	@go run perf/main.go -games 5 -pwc 100 -cpg 10 -use-main

drop:
	@psql -d postgres -f db/drop.sql > /dev/null
	@echo "Database created successfully!"

db-test migrate-test:
	@psql -h localhost -p 5432 -U postgres -d postgres -c "SHOW SERVER_VERSION"
	@go run main.go migrate -c ./config/test.yaml
	@go run main.go migrate -t 0 -c ./config/test.yaml
	@go run main.go migrate -c ./config/test.yaml

drop-test:
	@-psql -d postgres -h localhost -p 5432 -U postgres -c "SELECT pg_terminate_backend(pid.pid) FROM pg_stat_activity, (SELECT pid FROM pg_stat_activity where pid <> pg_backend_pid()) pid WHERE datname='khan_test';"
	@psql -d postgres -h localhost -p 5432 -U postgres -f db/drop-test.sql > /dev/null
	@echo "Test database created successfully!"

run-test-khan: build kill-test-khan
	@rm -rf /tmp/khan-bench.log
	@./khan start -p 8888 -c ./config/perf.yaml 2>&1 > /tmp/khan-bench.log &

kill-test-khan:
	@-ps aux | egrep './khan.+perf.yaml' | egrep -v egrep | awk ' { print $$2 } ' | xargs kill -9

ci-perf: drop-perf migrate-perf run-test-khan run-perf

run-perf:
	@go test -bench . -benchtime 3s ./bench/...

db-perf:
	@go run perf/main.go

restore-perf:
	@psql -d postgres -U postgres khan_perf < khan-perf.dump

dump-perf:
	@pg_dump khan_perf > khan-perf.dump

drop-perf:
	@psql -d postgres -U postgres -f db/drop-perf.sql > /dev/null
	@echo "Perf database created successfully!"

migrate-perf:
	@go run main.go migrate -c ./config/perf.yaml

static:
	@-go vet $(PACKAGES)
	@-gocyclo -over 5 . | egrep -v vendor/
	@for pkg in $$(go list ./... | grep -v /vendor/ | grep -v "/db") ; do \
        golint $$pkg ; \
    done
	@#ineffassign
	@for pkg in $(GODIRS) ; do \
        ineffassign $$pkg ; \
    done
	@${MAKE} pmd

pmd:
	@bash pmd.sh
	@for pkg in $(GODIRS) ; do \
		exclude=$$(find $$pkg -name '*_test.go') && \
		/tmp/pmd-bin-5.4.2/bin/run.sh cpd --minimum-tokens 30 --files $$pkg --exclude $$exclude --language go ; \
    done

pmd-full:
	@bash pmd.sh
	@for pkg in $(GODIRS) ; do \
		/tmp/pmd-bin-5.4.2/bin/run.sh cpd --minimum-tokens 30 --files $$pkg --language go ; \
    done

rtfd:
	@rm -rf docs/_build
	@sphinx-build -b html -d ./docs/_build/doctrees ./docs/ docs/_build/html
	@open docs/_build/html/index.html
