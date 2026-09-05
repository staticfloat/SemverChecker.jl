# Locating the latest registered version of a package.
#
# The source itself is no longer fetched here: the released version is installed
# by Pkg inside the worker subprocess, which is what makes it loadable.

"""
    RegisteredVersion

The newest non-yanked release of a package found in the reachable registries.
"""
struct RegisteredVersion
    name::String
    uuid::Base.UUID
    version::VersionNumber
    registry::String
end

"""
    latest_registered(name; uuid=nothing, registries=Pkg.Registry.reachable_registries())

Return the [`RegisteredVersion`](@ref) with the highest version number across all
reachable registries, or `nothing` when the package is not registered.

Yanked versions are ignored.  When `uuid` is given it must match, which keeps us
honest in the presence of name collisions between registries.
"""
function latest_registered(name::AbstractString;
                           uuid::Union{Nothing,Base.UUID}=nothing,
                           registries=Pkg.Registry.reachable_registries())
    best::Union{Nothing,RegisteredVersion} = nothing
    for reg in registries
        for (u, entry) in reg.pkgs
            entry.name == name || continue
            uuid === nothing || u == uuid || continue
            info = try
                Pkg.Registry.registry_info(entry)
            catch e
                @warn "could not read registry info" package=name registry=reg.name exception=e
                continue
            end
            for (v, vinfo) in info.version_info
                vinfo.yanked && continue
                if best === nothing || v > best.version
                    best = RegisteredVersion(name, u, v, reg.name)
                end
            end
        end
    end
    return best
end
