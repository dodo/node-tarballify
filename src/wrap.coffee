fs = require 'fs'
path = require 'path'
util = require 'util'
{ EventEmitter } = require 'events'
{ Pack:Tarball } = require 'tarball'
BufferStream = require 'bufferstream'
detective = require 'detective'
resolve = require 'resolve'
deputy = require 'deputy'
commondir = require 'commondir'
nub = require 'nub'

module.exports = (opts) -> new Wrap(opts)

idFromPath = (path) -> path.replace(/\\/g, '/')

class Wrap extends EventEmitter
    constructor: (opts = {}) ->
        home = process.env.HOME or process.env.USERPROFILE
        opts.cache ?= on if home?

        if opts.cache
            if typeof opts.cache is 'boolean'
                file = path.join(home, '.config/tarballify/cache.json')
                @detective = deputy(file)
            else
                @detective = deputy(opts.cache)
        else
            @detective = detective

        @tarball = new Tarball {noProprietary:yes},
            compress:on
            defaults:
                uname:'www'
                gname:'nogroup'
                uid: 1000
                gid: 1000
        @tarball.on('error', @emit.bind(this, 'error'))
        @tarball.setMaxListeners(0)

        @working = no
        @dirname = opts.dirname ? process.cwd()
        @exports = opts.exports
        @debug = opts.debug
        @piped = no

        @queue = []
        @files = []
        @filters = []

        @extensions = [ '.js' ]

    use: (fn) ->
        fn(this, this)
        return this

    has: (file) ->
        return yes if @files[file]
        return Object.keys(@files).some((key) => @files[key].target is file)

    end: () =>
        if @working
            @ending = yes
            @emit('wait')
        else
            @tarball.end()

    pipe: (dests...) ->
        console.warn("there might be dragons when you pipe twice.") if @piped
        @piped = yes
        src = @tarball
        while (dst = dests.shift())?
            src = src.pipe(dst).on('error', @emit.bind(this, 'error'))
        src.on('close', @emit.bind(this, 'close'))
        @emit('pipe')
        return src

    work: (job) ->
        if job?
            @working = yes
            process.nextTick(job.bind(this, => @work(@queue.shift())))
        else
            @working = no
            @end() if @ending

    _push: (job) ->
        if @working
            @queue.push(job)
        else
            @work(job)

    append: (file, content, opts = {}, callback) ->
        console.warn("WARN: no output specified.") unless @piped
        dirname = opts.dirname ? @dirname
        @files[file] = entry = {file}
        file = path.resolve(dirname, file)
        stream = new BufferStream disabled:yes # no splitting needed
        stream.path = entry.file
        unless opts.size?
            if path.existsSync(file)
                opts.size = fs.statSync(file).size
            else if typeof content is 'string'
                opts.size = new Buffer(content).length
            @emit('error', "no size for #{file}") unless opts.size?
        stream.props = size:opts.size
        @_push (done) ->
            @emit('append', stream)
            @tarball.append(stream, done)
            content or= fs.createReadStream(file)
            if typeof content is 'string'
                stream.end(content, opts.encoding ? 'utf-8')
            else
                content.pipe(stream)
        return entry

    register: (ext, fn) ->
        if typeof ext is 'object'
            fn = ext.wrapper
            ext = ext.extension
        else if fn
            @extensions.push(ext)
            @filters.push (body, file) =>
                if file.slice(-ext.length) is ext
                    fn.call(this, body, file)
                else body
        else
            @filters.push(ext)
        return this

    readFile: (file) ->
        body = fs.readFileSync(file, 'utf-8')
        for fn in @filters
            body = fn.call(this, body, file)
        return body

    addEntry: (filename, opts = {}, callback) ->
        file = path.resolve(opts.dirname ? @dirname, filename)
        body = opts.body ? @readFile(file)

        try required = @detective.find(body)
        catch err
            err.message = "Error while loading entry file " +
                "#{JSON.stringify(file)}: #{err.message}"
            process.nextTick( => @emit('syntaxError', err))
            return this
        if required.expressions.length
            console.error("Expressions in require() statements:")
            for ex in required.expressions
                console.error("    require(#{ex})")

        entry = @append(filename, body, dirname:opts.dirname)
        entry.target = opts.target if opts.target?

        dirname = path.dirname(file)
        for req in required.strings
            params = {dirname, fromFile:entry.file}
            if opts.target and /^[.\/]/.test(req)
                params.target = path.resolve(path.dirname(opts.target), req)
            @require(req, params)
        return this

    resolver: (file, basedir) ->
        resolve.sync(file, {basedir, @extensions})

    require: (mfile, opts = {}) ->
        opts.dirname ?= @dirname
        return this unless not @has(mfile) and
            not resolve.isCore(mfile)      and
            not (opts.target? and @has(opts.target))
        moduleError = (msg) ->
            new Error "#{msg}: #{JSON.stringify mfile} " +
                "from directory #{JSON.stringify opts.dirname}" +
                (opts.fromFile? and " while processing file #{opts.fromFile}" or "")
        opts.file = mfile if opts.body
        unless opts.file
            try
                if path.normalize(path.resolve(mfile)) is path.normalize(mfile)
                    normPath = path.normalize(mfile)
                else
                    normPath = mfile
                opts.file = @resolver(normPath, opts.dirname)
            catch err
                throw moduleError "Cannot find module. #{err?.message}"
        return this if @has(opts.file)
        dirname = path.dirname(opts.file)
        pkgfile = path.join(dirname, 'package.json')
        unless /^(\.\.?)?\//.test(mfile)
            try pkgfile = resolve.sync path.join(mfile, 'package.json'),
                basedir:dirname
            catch err # nothing
        if pkgfile and not @files[pkgfile]
            if path.existsSync(pkgfile)
                pkgbody = "module.exports=" + fs.readFileSync(pkgfile, 'utf-8')
                @append(pkgfile, pkgbody, {dirname})
            else pkgfile = null

        body = opts.body ? @readFile(opts.file)

        try required = @detective.find(body)
        catch err
            err.message = "Error while loading file " +
                "#{JSON.stringify(opts.file)}: #{err.message}"
            process.nextTick( => @emit('syntaxError', err))
            return this
        if required.expressions.length
            console.error("Expressions in require() statements:")
            for ex in required.expressions
                console.error("    require(#{ex})")

        entry = @append(opts.file, body, {dirname})
        entry.target = opts.target

        for req in nub(required.strings)
            params = {dirname, fromFile:entry.file}
            if opts.target and /^[.\/]/.test(req)
                # not a real directory on the filesystem; just using the path
                # module to get rid of the filename.
                targetDir = path.dirname(opts.target)
                # not a real filename; just using the path module to deal with
                # relative paths.
                reqFilename = path.resolve(targetDir, req)
                # get rid of drive letter on Windows; replace it with '/'
                reqFilenameWithoutDriveLetter = if /^[A-Z]:\\/.test(reqFilename)
                        '/' + reqFilename.substring(3)
                    else reqFilename

                params.target = idFromPath(reqFilenameWithoutDriveLetter)
            @require(req, params)

        return this


