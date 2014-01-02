![TARBALLIFY ALL THE THINGS!](/dodo/node-tarballify/raw/master/23182620.jpg)

Put all the things from your server in one tarball.

```javascript
var fs = require('fs')
var path = require('path')
var tarballify = require('tarballify')

console.log("creating new tarball …")
var tarball = tarballify('./server.js', {
    dirname:__dirname,
    fileList:false, // include a FILES file with a list of all files when true
})
    .register(".node", function (body, file) {
        console.log("skip binary file:", file)
        return "skip binary"
    })
    .on('warn',  function(w){console.warn( "WARN",w)})
    .on('error', function(e){console.error("ERR ",e)})
    .on('skip',  function(s){console.log(  "skip",s.name,s.dirname)})
    .on('wait',  function( ){console.log("waiting for tarball to finish …")})
    .on('append',function(f){console.log("append",f.props.size, "\t",f.path)})
    .on('close', function( ){console.log("done.")})
    .on('syntaxError', function(e){console.error("syntaxError ",e)})
tarball.pipe(fs.createWriteStream(path.join(__dirname, "test.tar.gz")))
tarball.append("README.md")

console.log("setup ok.")
tarball.end()
```
