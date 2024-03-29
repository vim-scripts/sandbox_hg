" sandbox.vim: Quick & dirty Vim script for managing subversion sandbox
" Author: Wenzhi Liang <wenzhi.liang _at_ gmail.com>
"
" Licence: This program is free software; you can redistribute it and/or
"          modify it under the terms of the GNU General Public License.
"          See http://www.gnu.org/copyleft/gpl.txt 
"
" Install:
" This plugin will be distributed as a vimball. So simply edit the vimball and
" :so it.
"
" Usage:
" ':Sandbox <sandboxhg_directory>' on the command line will create a new buffer
" which list the current status of the sandbox. In the buffer, a few handy
" mapping are available like diffing, commit, revert, etc. See the help at 
" the bottom of the buffer. It's not meant to be a do-it-all front-end to the
" svn command line tool. Just a couple of wrappers for frequently used operations.
"
" Configuration:
" - Define an array called g:sandboxhg_prefered_gui_diff as a sequence of preferred
"   gui diffing tool, in that order.  E.G. in your vimrc file, 'let
"   g:sandboxhg_prefered_gui_diff=['meld','tkdiff'] will cause this script to
"   search and use meld, in the absence of which, tkdiff.
" - If you have vcscommand.vim installed and would like to use it for diffing,
"   logging, etc, add 'let g:sandboxhg_use_vcscommand=1' in your .vimrc file
" - The g:sandboxhg_look_for_updates switch can be used to ignore looking for
"   updates. This will improve the speed on startup. By default it's set to 1
"   though.
"
" Requirement:
" - This is only tested on Linux with svn 1.6. However, it should work on any platform where
"   svn command is working. 
" - If you're using ssh with your subversion server, you'd have to configure the
"   ssh-agent yourself.
" - This script can be used together with vcscommand.vim. It doesn't look
"   for it though.
"
" BUG:
" - the sandbox location var is shared between all windows.
" - doesn't work too well with multi-line status
" - Checking comment is expanded!
" - There is problem with updating a directory.
"
"
" """""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

if exists("sandboxhg_loaded")
    finish
else
    let sandboxhg_loaded=1
endif

" Default configuration {{{
if !exists("g:sandboxhg_prefered_gui_diff")
    let g:sandboxhg_prefered_gui_diff=['diffuse', 'meld']
endif

if !exists("g:sandboxhg_use_vcscommand")
    let g:sandboxhg_use_vcscommand = 0
endif

if !exists("g:sandboxhg_look_for_updates")
    let g:sandboxhg_look_for_updates = 1
endif
"}}}

" {{{ Local vars
let s:sandboxhg_buffer_name = '__sandboxhg__'
let g:sandboxhg_root_dir=""
let b:selected_files=[]
let s:svn_msg=""
let b:first_line = 0
let b:last_line = 0
let s:supported_gui_diff=['diffuse', 'meld']
let s:gui_diff_cmd=""
let s:gui_log_cmd="hgtk log"
let s:gui_blame_cmd="hgtk blame"
let b:help_line_number=0

let s:commit_prompt = "Commit message, no quotation marks (leave blank to cancel): "
let s:revertall_prompt = "Are you sure you want to revert the hilighted files? " 
let s:anycommand_prompt = "Input the svn command you want to run (without the svn part): "

let s:debug = 0

let s:st_dict = { 
            \ 'A':'Added', 
            \ 'C':'Conflicted', 
            \ 'D':'Deleted', 
            \ 'I':'Ignored', 
            \ 'M':'Modified', 
            \ 'R':'Replaced',
            \ 'S':'Switched', 
            \ 'X':'Externally defined', 
            \ '?':'Unknown', 
            \ '!':'Locally removed', 
            \ '~':'Obstructed', 
            \}
" }}}

" {{{ Check requirment, doesn't return
if !executable('svn')
    echoerr "Dependency error: missing svn."
    finish
endif

if version < 700
    echoerr "Dependency error: Vim version older than 7.0."
    finish
endif


" Detect gui tools anyway 
for d in g:sandboxhg_prefered_gui_diff
    if index( s:supported_gui_diff, d) < 0
        continue
    endif
    if executable( d )
        let s:gui_diff_cmd=d
        break
    endif
endfor

if !executable('hgtk')
    echo "It's recommended that you install tortoisehg."
endif

if s:gui_diff_cmd == ""
    echoerr "No external GUI diffing tool found."
    let g:sandboxhg_use_vcscommand = 1
endif
"}}}

" debug
function! <SID>_Debug(msg)
    if s:debug == 1
        echo a:msg
    endif
endfunc

"Check if the current line is indeed part of the "hg st" log
function! <SID>__IsStatusLine(l)
    if b:first_line == 0
        return 0
    endif

    if a:l < b:first_line || a:l > b:last_line
        return 0
    else
        return 1
    endif
endfunc


"Prompt the user, return a boolean to indicate if following action should be taken or not
function! <SID>__Prompt(p)
    let ans = input(a:p)
    if ans != ""
        let b:svn_msg=ans
        return 1
    else
        let b:svn_msg=""
        return 0
    endif
endfunc

"Tag (select) a file for command over multiple files
function! <SID>TagLine()
    exe 'lcd ' . g:sandboxhg_root_dir
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    setlocal modifiable
    let l = getline('.')
    let idx = -1
    let fn = ""
    if l =~ ' (+)$'
        .s/ (+)//g
        let l = getline('.')
        let fn = <SID>GetFileNameCheck(l)
        let idx = index( b:selected_files, fn )
    else
        let fn = <SID>GetFileNameCheck(l)
        exec "normal  A (+)"
    endif

    if idx != -1
        call remove( b:selected_files, idx )
        "echo b:selected_files
    else
        call add(b:selected_files, fn)
        "echo b:selected_files
    endif
    setlocal nomodifiable
    normal j
endfunc

"Reset selection
function! <SID>UnselectAll()
    let b:selected_files=[]

    setlocal modifiable
    %s, (+)$,,g
    setlocal nomodifiable
endfunc

"Jump to the help section in the buffer
function! <SID>GoToHelp()
    exe "normal " . b:help_line_number . "G"
endfunc 

"Get a file name from a line, returns 'XXX' when the line isn't a svn log
" According to 'svn help st', the first 9 columns are for status and the rest
" should be revision number and the path " detail, space delimetered.
function! <SID>GetFileName(l)
    exe 'lcd ' . g:sandboxhg_root_dir
    let foo = substitute( a:l, '^.\{2}', '' ,'g')
    call <SID>_Debug( "foo: " . foo)
    return foo " return blindly as sometimes a file is missing.
    endif
endfunc

" Same as above but check the validaty of the file/dir
function! <SID>GetFileNameCheck(l)
    let fn=<SID>GetFileName(a:l)
    if filereadable(fn) || isdirectory(fn)
        return fn
    else
        return "XXX"
    endif
endfunc

"Run svn command on a single file or a list of files
function! <SID>__ExeSvnCommand(cmd, list, silent)
    exe 'lcd ' . g:sandboxhg_root_dir
    if type(a:list) == 3 "actually a list
        let cli = "hg " . a:cmd . ' ' . join(a:list, ' ')
    else "Assuming it is a string
        let cli = "hg " . ' ' . a:cmd . ' "' . a:list . '"'
    endif
    call <SID>_Debug( cli )
    if s:debug == 1
        return
    endif
    if a:silent
        silent exec '!' . cli
    else
        exec '!' . cli
    endif
endfunc

"Run svn command on sellected files
function! <SID>__ExeSvnMassCommand(cmd)
    call <SID>__ExeSvnCommand( a:cmd, b:selected_files, 1 )
    call <SID>UpdateBuffer(0)
endfunc


"Remove the current line when it is not needed anymore, dd will not work because
"'d' is mapped to sth else.
function! <SID>__RemoveCurrentLine()
    let save_reg=@"
    setlocal modifiable
    normal 0DgJ
    setlocal nomodifiable
    let @"=save_reg
    let b:help_line_number -= 1 
    let b:last_line -= 1
endfunc

function! <SID>__MoveToMainWindow()
    wincmd j
    exe "lcd " . g:sandboxhg_root_dir
endfunc

"Do revert on the current log line
function! <SID>Revert()
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    let l = getline('.')
    let fn = <SID>GetFileNameCheck(l)
    if fn != "XXX"
        let ans = input("Are you sure you want to revert changes made in " . fn . '? ') 
        if toupper(ans) == 'Y' 
            call <SID>__ExeSvnCommand( 'revert', fn, 1 )
            call <SID>__RemoveCurrentLine()
        endif
    endif
endfunc

"Commit single file on current line
function! <SID>Commit()
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    let l = getline('.')
    call <SID>_Debug( l )
    let fn = <SID>GetFileNameCheck(l)
    if fn != "XXX"
        let ans = input("Commit message, no quotation marks (leave blank to cancel): ") 
        if ans != ""
            call <SID>__ExeSvnCommand( 'commit -m ' . '"' . ans . '"', fn, 1 )
            call <SID>__RemoveCurrentLine()
        endif
    endif
endfunc

"Resolved single file
function! <SID>Resolved()
endfunc

"Revert on a range of lines...
function! <SID>RevertAll()
    if len( b:selected_files ) == 0
        call <SID>Revert()
        return
    endif
    let ans = input(s:revertall_prompt)
    if toupper(ans) != 'Y' 
        return
    endif
    call <SID>__ExeSvnMassCommand('revert')
endfunc

"Commit on a range of lines
function! <SID>CommitAll()
    if len( b:selected_files ) == 0
        call <SID>Commit()
        return
    endif
    let cont=<SID>__Prompt( s:commit_prompt )
    if cont 
        call <SID>__ExeSvnMassCommand('commit -m ' . '"' . b:svn_msg . '"')
    else
        echo "Operation canceled."
    endif
endfunc


"Resolved single file
function! <SID>ResolvedAll()
    if len( b:selected_files ) == 0
        call <SID>Resolved()
        return
    endif
    call <SID>__ExeSvnMassCommand('resolved')
endfunc

"Update a line
function! <SID>Update()
    exe 'lcd ' . g:sandboxhg_root_dir
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    let l = getline('.')
    if  l !~ '^.       \*' && l !~ '^!' 
        echo "Nothing to be done"
        return
    endif
    let fn = <SID>GetFileName(l)
    if fn != "XXX"
        echo "updating " . fn
        call <SID>__ExeSvnCommand( "update -q --accept 'postpone'",  fn, 1 )
        setlocal modifiable
        let svnst = system("svn st -q " . fn )
        if strlen(svnst) == 0
            call  <SID>__RemoveCurrentLine()
        else
            call setline('.', svnst )
        endif
        setlocal nomodifiable
    else
        echo "Wrong file name. "
    endif
endfunc

function! <SID>UpdateTagged()
    if len( b:selected_files ) == 0
        call <SID>Update()
        return
    endif
    call <SID>__ExeSvnMassCommand("update -q --accept 'postpone'")
endfunc


function! <SID>UpdateAll()
    exe 'lcd ' . g:sandboxhg_root_dir
    echo "Update whole sandbox..."
    call <SID>__ExeSvnCommand( "update -q --accept 'postpone'", ".", 1 )
    call <SID>UpdateBuffer(0)
endfunc


"{{{ wrapper for :commands
function! <SID>Diff()
    call <SID>ExternalTools('diff')
endfunc

function! <SID>Log()
    call <SID>ExternalTools('log')
endfunc

function! <SID>Blame()
    call <SID>ExternalTools('blame')
endfunc
" }}}

" {{{ Get log for current line
function! <SID>TkcvsLog(fn)
    silent exe '!' . s:gui_log_cmd . ' ' . a:fn 
endfunc

"Get log fot current line
function! <SID>VCSLog(fn)
    call <SID>__MoveToMainWindow()
    exe "e " . a:fn
    VCSLog
endfunc
" }}}

" {{{ Get blame for current line
function! <SID>TkcvsBlame(fn)
    silent exe '!' . s:gui_blame_cmd . ' ' . a:fn 
endfunc

"Get log fot current line
function! <SID>VCSBlame(fn)
    call <SID>__MoveToMainWindow()
    exe "e " . a:fn
    VCSBlame
endfunc
" }}}
"
"{{{Diff single file on current line
"Has to be called by Diff()
function! <SID>GUI_Diff(f)
    silent exe '!' . s:gui_diff_cmd . ' ' . a:f . '&'
endfunc

"Diff single file on current line
"Has to be called by Diff()
function! <SID>VCS_Diff(f)
    call <SID>__MoveToMainWindow()
    exe "e " . a:f
    VCSVimDiff
endfunc
"}}}


"We don't support diffing multiple files.
function! <SID>ErrDiffRange() range
    echoerr "Diff operation is not available on range" 
endfunc


let s:Func_gui_diff = function("<SID>GUI_Diff")
let s:Func_vcm_diff = function("<SID>VCS_Diff")
let s:Func_gui_blame = function("<SID>TkcvsBlame")
let s:Func_vcs_blame = function("<SID>VCSBlame")
let s:Func_gui_log = function("<SID>TkcvsLog")
let s:Func_vcs_log = function("<SID>VCSLog")
let s:gui_cmd_dict = { 'diff': s:Func_gui_diff, 'blame':s:Func_gui_blame, 'log':s:Func_gui_log }
let s:vcs_cmd_dict = { 'diff': s:Func_vcm_diff, 'blame':s:Func_vcs_blame, 'log':s:Func_vcs_log }

"Wrapper for GUI/VCS commands
function! <SID>ExternalTools(cmd)
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    let l = getline('.')
    let fn = <SID>GetFileNameCheck(l)
    if fn == "XXX"
        return
    endif

    let ToCall = s:vcs_cmd_dict[ a:cmd ]
    if !g:sandboxhg_use_vcscommand 
        let ToCall = s:gui_cmd_dict[ a:cmd ]
    endif

    if !s:debug 
        call ToCall(fn)
    endif
    redraw
    redraw
endfunc

" Load the file into window below
function! <SID>Edit()
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    exe 'lcd ' . g:sandboxhg_root_dir
    let l = getline('.')
    let fn = <SID>GetFileNameCheck(l)
    if fn != "XXX"
        call <SID>__MoveToMainWindow()
        silent exe "e " . fn
    endif
endfunc


"Show tooltip about the status of the current file    
function! <SID>ShowStatusTip()
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    let num=0 "TODO: support more column
    let ch=getline('.')[num]
    let fn=<SID>GetFileNameCheck(getline('.'))
    "try
        echo s:st_dict[ch] fn
    "catch /.*/
        "echo "Unknown problem" ch
    "endtry
endfunc


" Run arbitrary svn command from the user
function! <SID>AnyCommand()
    if len( b:selected_files ) != 0
        echo "Undo all selections. This command is currently only available for a single file."
        return
    endif
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        return
    endif
    exe 'lcd ' . g:sandboxhg_root_dir
    let l = getline('.')
    let fn = <SID>GetFileNameCheck(l)
    if fn != "XXX"
        let cont=<SID>__Prompt( s:anycommand_prompt )
        if cont 
            call <SID>__ExeSvnCommand( b:svn_msg, fn, 0 )
        endif
    endif
endfunc

"Assumption: buffer is modifiable
function! <SID>UpdateToolSelection()
    let ln=line('.')
    setlocal modifiable
    if g:sandboxhg_use_vcscommand
        exe b:help_line_number . ",$s/ +GUI+ / GUI /g"
        exe b:help_line_number . ",$s/ VCS / +VCS+ /g"
    else
        exe b:help_line_number . ",$s/ GUI / +GUI+ /g"
        exe b:help_line_number . ",$s/ +VCS+ / VCS /g"
    endif
    setlocal nomodifiable
    exe ln
endfunc

function! <SID>PrintHelp()
    setlocal modifiable
    normal Go
    let b:help_line_number=line('.')
    call setline('.', " ---------- H E L P -----------" )
    normal o
    call setline('.', " c       Commit a single file or selected files.")
    normal o
    call setline('.', " d       Diff the file specified in the current line.")
    normal o
    call setline('.', " e       Open the file in question in a new tab.")
    normal o
    call setline('.', " o       Open a log tree browser.")
    normal o
    call setline('.', " m       Run blame command on the current file.")
    normal o
    call setline('.', " r       Revert a single file or selected files." )
    normal o
    call setline('.', " t       Select/Unselect a single file." )
    normal o
    call setline('.', " C-D     Reset selection.")
    normal o
    call setline('.', " <F5>    Refresh the buffer.")
    normal o
    if g:sandboxhg_use_vcscommand
        call setline('.', " <F6>    Switch between external GUI or +VCS+ plugin.")
    else
        call setline('.', " <F6>    Switch between external +GUI+ or VCS plugin.")
    endif
    normal o
    call setline('.', " q       Quit")
    normal o
    call setline('.', " ?       Jump to HELP.")
    setlocal nomodifiable
endfunc

function! <SID>UpdateBuffer(first)
    if !a:first
        echo "Refreshing svn result....."
    endif
    exe "lcd  " . g:sandboxhg_root_dir
    mapclear <buffer>
    setlocal modifiable
    normal ggdG
    "Somehow this command will leave an empty first line in the buffer
    :silent r!hg st -q
    " The first line is always empty
    let b:first_line = 2
    let b:last_line = line('$')
    " when updates is on, the last line is "Status against..."
    "if g:sandboxhg_look_for_updates
    "    let b:last_line -= 1
    "endif
    normal gg
    call setline('.', 'Current sandbox: ' . g:sandboxhg_root_dir)

    call <SID>PrintHelp()
    normal ggj
    call <SID>__SetupMapping()
    setlocal nomodifiable

    "Reset the selection
    let b:selected_files=[]
endfunc

function! <SID>__SetupMapping()
    nnoremap <buffer> <silent> r :call <SID>RevertAll()<CR>
    nnoremap <buffer> <silent> d :call <SID>Diff()<CR>
    vnoremap <buffer> <silent> d :call <SID>ErrDiffRange()<CR>
    nnoremap <buffer> <silent> c :call <SID>CommitAll()<CR>
    nnoremap <buffer> <silent> o :call <SID>Log()<CR>
    nnoremap <buffer> <silent> m :call <SID>Blame()<CR>
    nnoremap <buffer> <silent> t :call <SID>TagLine()<CR>
    nnoremap <buffer> <silent> x :call <SID>AnyCommand()<CR>
    nnoremap <buffer> <silent> e :call <SID>Edit()<CR>
    nnoremap <buffer> <silent> <F5> :call <SID>UpdateBuffer(0)<CR>
    nnoremap <buffer> <silent> <F6> :call <SID>SwitchFrontEnd()<CR>
    nnoremap <buffer> <silent> <C-D> :call <SID>UnselectAll()<CR>
    nnoremap <buffer> <silent> q :bwipeout!<CR>
    nnoremap <buffer> <silent> ? :call <SID>GoToHelp()<CR>
    nnoremap <buffer> <silent> <Leader>g :call <SID>Manifest()<CR>
endfunc

"Initialise the buffer and set mapping
function! <SID>CreateBuffer(p)
    if !isdirectory(a:p)
        echoerr "Invalid directory name."
        return
    endif
    echo "Getting list of changes for " . a:p . "..."
    exec "silent 18split " . s:sandboxhg_buffer_name . a:p
    let g:sandboxhg_root_dir = a:p
    "exe "lcd  " . a:p
    " TODO: The following command should be an more elegant solution than
    " entering directory each time a function is called. However, it doesn't
    " work....
    "exec "au BufEnter <buffer> lcd " . b:sandboxhg_root_dir
    au CursorHold <buffer> :call <SID>ShowStatusTip()

    setlocal buftype=nofile
    "47 is '/'
    setlocal isk+=47-57,_,a-z,A-Z
    setlocal nowrap
    setlocal textwidth=999
    syn clear
    syn match SvnDiffModified "^M\>"
    syn match SvnDiffConflict "^C\>"
    syn match SvnDiffSelected " (+)$"
    syn match SvnDiffRevision "\<\d\+\>"
    hi link SvnDiffModified Identifier
    hi link SvnDiffConflict Error
    hi link SvnDiffSelected Keyword
    hi link SvnDiffRevision Number
    call <SID>UpdateBuffer(1)
endfunc

" switch between gui or VCS plugin front end
function! <SID>SwitchFrontEnd()
    if g:sandboxhg_use_vcscommand
        let g:sandboxhg_use_vcscommand = 0
    else
        let g:sandboxhg_use_vcscommand = 1
    endif
    call <SID>UpdateToolSelection()
endfunc

function! <SID>Manifest()
    echo "root: " g:sandboxhg_root_dir
    echo "selected: " b:selected_files
    echo "first_line: " b:first_line
    echo "last_line: " b:last_line
    echo "gui_diff_cmd: " s:gui_diff_cmd
    echo "help_line_number: " b:help_line_number
    let num=line('.')
    if ! <SID>__IsStatusLine(num)
        echo "Non status line."
        return
    endif
    let fn = <SID>GetFileNameCheck(getline('.'))
    echo "file name: " fn
endfunc

"""""""""""""""""""""""""""""""""
" MAIN
"""""""""""""""""""""""""""""""""
if !exists(":Sandhg")
    command! -nargs=1 -complete=dir Sandhg call <SID>CreateBuffer(<q-args>)
endif

finish


Files:
plugin/sandbox_hg.vim

ChangLog: {{{
Fri Feb 17 Basic functionality working.
          }}}

" EoF vim:ts=4:sw=4:et:
