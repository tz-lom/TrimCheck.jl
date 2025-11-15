# TrimCheck.jl

TrimCheck.jl is a Julia package for validating code compatibility with Julia's `--trim` compiler option. The `--trim` option enables aggressive code trimming, removing unused methods and code paths to reduce binary size and improve performance. However, not all code is compatible with trimming, especially if it relies on dynamic features or type instability.

![License](https://img.shields.io/github/license/tz-lom/TrimCheck.jl) ![GitHub branch status](https://img.shields.io/github/checks-status/tz-lom/TrimCheck.jl/master) ![GitHub Tag](https://img.shields.io/github/v/tag/tz-lom/TrimCheck.jl)
[![Documentation](https://img.shields.io/badge/Documentation-blue)
](https://tz-lom.github.io/TrimCheck.jl)

## Usage

    @check_calls [init=initialization code] [verbose=true] call, [call,...]

- Generates a `@testset` with tests that check whether every `call` can be fully type-inferred.
- The test is executed in a separate Julia process, which inherits the current project environment.
- `init` is the code that sets up the environment for the test in that process.
- `verbose` is passed as a parameter to `@testset`.

This is an early version of the package and the API may be subject to change.

## How It Works

- The macro `@check_calls` takes an optional initialization block and a list of function calls to check.
- It spawns a Julia subprocess, pre-loads trim workarounds, loads the `init` section, and attempts to type-infer each call.
- Results are reported as test cases: passing if the call is compatible with trimming, failing otherwise.

## Example

Suppose you have a package and want to test a function from it:

```julia
module YourPackage
    struct TypeUnstable
        x # This field implicitly has type Any
    end
    struct TypeStable
        x::Union{Float64,Int64} # This is a finite set of types
    end
    function foo(x)
        show(Core.stdout, "=$x=") # Note: the default `show` uses a runtime feature for selecting the output stream, which is not trim compatible.
    end
end
```

This is best suited for test code, as it declares a `@testset` from the `Test` package:

```julia
@check_calls(init = begin              # 'init' is executed before the test
        using YourPackage
    end, verbose = true,               # 'verbose' is true by default
    YourPackage.foo(Int32),            # function signatures to test
    YourPackage.foo(String),
    YourPackage.foo(TypeUnstable),     # this function call will be reported as problematic
    YourPackage.foo(TypeStable))
```

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
