#!/usr/bin/make

jenkins_jobs ?= jenkins-jobs
jenkins_jobs_ini ?= jenkins_jobs.ini
outdir ?= ./generated_xml

all: usage

usage:
	@echo "USAGE:"
	@echo "  make clean      # Delete all the autogenerated files from $(outdir)"
	@echo "  make test       # Generate test output in $(outdir)"
	@echo "  make update     # Update jobs on the live jenkins instance"
	@echo
	@echo "Edit jenkins_jobs.ini before running make dist."

$(outdir):
	mkdir -p $(outdir)

clean: $(outdir)
	find $(outdir) -maxdepth 1 -type f ! -name README -delete

test: clean
	@$(jenkins_jobs) --conf $(jenkins_jobs_ini) --user $(USER) --password $(PASSWORD) test -o $(outdir) jobs

update: clean
	@$(jenkins_jobs) --conf $(jenkins_jobs_ini) --user $(USER) --password $(PASSWORD) --ignore-cache update jobs
