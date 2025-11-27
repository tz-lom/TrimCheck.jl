using Changelog
using Documenter
using TrimCheck

# Generate a Documenter-friendly changelog from CHANGELOG.md
Changelog.generate(
    Changelog.Documenter(),
    joinpath(@__DIR__, "..", "CHANGELOG.md"),
    joinpath(@__DIR__, "src", "release-notes.md");
    repo = "tz-lom/TrimCheck.jl",
)

makedocs(;
    sitename = "TrimCheck.jl",
    modules = [TrimCheck],
    authors = "Yury Nuzhdin",
    format = Documenter.HTML(; prettyurls = haskey(ENV, "CI")),
    checkdocs = :exports,
    pages = [
        "TrimCheck.jl" => "index.md",
        "API" => "api.md",
        "Release Notes" => "release-notes.md",
    ],
)

deploydocs(; repo = "github.com/tz-lom/TrimCheck.jl.git", push_preview = true)
