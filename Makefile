.PHONY: run shell clean

run:
	export $$(cat .env | xargs) && rebar3 shell

shell:
	rebar3 shell

clean:
	rebar3 clean

fmt:
		rebar3 fmt
