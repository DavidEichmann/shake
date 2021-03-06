# Shake HTML

HTML files used by Shake, primarily for profiling.

## Files

There are a number of HTML files which contain end user interfaces:

* `convert.html` is prototype interactive `Makefile` to Shake script converted. Never really got finished. Not in a workable state.
* `demo.html` is a guided tutorial through the profiling steps.
* `profile.html` is the actual profiler.
* `progress.html` is for viewing and debugging the progress reporting.
* `test.html` runs the tests of the profiling JavaScript code. It should be manually rerun after you edit the profiling code.

There are a number of JavaScript files:

* `profile-data.js`, `progress-data.js` and `version.js` are files with sample data, matching that generated by the compiler.
* `viz.js` is a JavaScript library, a compiled version of GraphViz.
* `shake.js` is generated from the code in `ts`.

## Development

Before doing any work you need the jQuery and Flot JavaScript dependencies. These can be found in the `js-jquery` and `js-flot` repos. Copy the associated JavaScript files into a `lib` directory, renaming to take away version numbers and `.min` parts.

To build and test `shake.js` from `html` run:

    tsc -p ts               # generated shake.js
    tslint -p ts            # run the linter
    node test.js            # run the tests

Or, for the one liner:

    tsc -p ts && tslint -p ts && node test.js

To test out the `profile.html` just open it after doing the above steps.
