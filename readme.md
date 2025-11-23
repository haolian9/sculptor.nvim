an example implementation to format nvim buffers

## features
* profiles of formatters for each filetype/language
* use diff+patch to update the buffer
* rate limit

## design choices
* assume all external formatting programs accepts a file argument and format inplace
* no need to write buffer first before formatting
* run multiple runners by order, crashes should not make the source buffer dirty

## status
* just works(tm)
* the use of ffi may crash nvim
* no more formatters are planned

## prerequisites
* linux
* nvim 0.11.*
* haolian9/infra.nvim
* haolian9/cthulhu.nvim

