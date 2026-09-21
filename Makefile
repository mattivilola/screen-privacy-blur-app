.PHONY: run

run:
	@set -eu; \
	output_dir="$(CURDIR)/artifacts/local/run-$$(uuidgen)"; \
	./scripts/build-local-app.sh "$$output_dir"; \
	open "$$output_dir/Screen Privacy.app"
