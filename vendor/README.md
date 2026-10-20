# Vendored dependencies

## cJSON

`cJSON.c` and `cJSON.h`, version 1.7.19 (`CJSON_VERSION_*` in `cJSON.h`), MIT licensed, used
by the signature database loader. When updating, compare with the current cJSON release and
its security fixes.

## JsonCpp

`steam-shim/jsoncpp.cpp` and `steam-shim/json/`, the amalgamated JsonCpp 1.6.5
(`JSONCPP_VERSION_STRING`), public domain / MIT, used by steam-shim.

## Dobby

Apache 2.0 licensed, isn't tracked in repo, clone it at the commit used by this project:

    git clone https://github.com/jmpews/Dobby.git vendor/dobby
    git -C vendor/dobby checkout 5dfc8546954ce3b3198132ab13fddb89ee92cdd7

Then run `make dobby`, which builds it into `build/dobby/`. If you change the commit, check that the hooks still install, and update
`DOBBY_COMMIT` in `.github/workflows/app.yml` to match.
