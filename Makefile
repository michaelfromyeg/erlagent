.PHONY: run shell clean

run:
	rebar3 compile && erl -pa _build/default/lib/erlagent/ebin -noshell -eval 'erlagent_app:main(), halt().'

shell:
	rebar3 shell

clean:
	rebar3 clean
