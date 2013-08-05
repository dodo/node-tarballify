wrap = require './wrap'
{ isArray } = Array


module.exports = (entryFile, opts = {}) ->

    if isArray entryFile
        if isArray opts.entry
            opts.entry = entryFile.concat(opts.entry)
        else if opts.entry
            entryFile.push(opts.entry)
            opts.entry = entryFile
        else
            opts.entry = entryFile
    else if typeof entryFile is 'object'
        opts = entryFile
    else if typeof entryFile is 'string'
        if isArray opts.entry
            opts.entry.unshift(entryFile)
        else if opts.entry
            opts.entry = [ entryFile, opts.entry ]
        else
            opts.entry = entryFile

    res = wrap(opts)
    res.once('pipe', -> res.addEntry(entryFile))