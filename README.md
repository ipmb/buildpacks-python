An experimental [cloud-native Buildpack](https://buildpacks.io/) (CNB) for Python on the Heroku stack.

## Motivation

Heroku's current Python buildpack has not been upgraded to CNB and instead [uses a shim](https://jkutner.github.io/2020/05/26/cloud-native-buildpacks-shim.html) to work in that environment. Heroku is upgrading all their stacks, but I got tired of waiting and wanted to learn more about buildpacks in the process.

This used the excellent [Node.js cloud-native Buildpack](https://github.com/heroku/heroku-buildpack-nodejs) as a starting point and adjusted to work with Python.

## Goals

* Support all major Python package managers out-of-the-box
* Allow other package managers to work via [PEP-517](https://www.python.org/dev/peps/pep-0517/)
* Handle all configuration in `pyproject.toml`, dropping support for `runtime.txt` and some of the magic (Django collectstatic) that's in the current buildpack.

## Status

* ✅ `poetry`
* ✅ `pdm`
* ⛔️ `pipenv`
* ⛔️ PEP-517 builds
* ⛔️ `requirements.txt`

## Configuration

The following keys are supported in `pyproject.toml`:

* `tools.heroku`
   * `prebuild` command to run before install
   * `postbuild` command to run after install
   * `engines`
      * `python` version of Python to install, defaults to `3.9.*`
      * `poetry` version of poetry to install, defaults to `1.*`
      * `pdm` version of pdm to install, defaults to `1.*`
      * `pip` version of pip to install, defaults to latest

## To-do

* Make `setuptools` version configurable like `pip`
* `pipenv` buildpack
* `requirements.txt` buildpack
* `PEP-517` buildpack (`pip install .` when `pyproject.toml` exists)
* Use `resolve-version` to bust cache when newer versions of pdm or poetry released
* Use `project.requires-python` in `pyproject.toml` to determine Python version
* Don't hardcode stack for Python download
* Handle max versions of pip/setuptools for older Pythons
* Tests