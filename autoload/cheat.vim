" Vim plugin for accessing cheat sheets from cheat.sh.
" Maintainer: David Beniamine
"
" Copyright (C) 2018 David Beniamine. All rights reserved.
"
" This program is free software: you can redistribute it and/or modify
" it under the terms of the GNU General Public License as published by
" the Free Software Foundation, either version 3 of the License, or
" (at your option) any later version.
"
" This program is distributed in the hope that it will be useful,
" but WITHOUT ANY WARRANTY; without even the implied warranty of
" MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
" GNU General Public License for more details.
"
" You should have received a copy of the GNU General Public License
" along with this program.  If not, see <http://www.gnu.org/licenses/>.

let save_cpo = &cpo
set cpo&vim

" Vim command used to open new buffer
if(!exists("g:CheatSheetReaderCmd"))
    let g:CheatSheetReaderCmd='new'
endif

" Cheat sheet file type
if(!exists("g:CheatSheetFt"))
    let g:CheatSheetFt='markdown'
endif

" Program used to retrieve cheat sheet with its arguments
if(!exists("g:CheatSheetUrlGetter"))
    let g:CheatSheetUrlGetter='curl --silent'
endif

" cheat sheet settings
if(!exists("g:CheatSheetUrlSettings"))
    let g:CheatSheetUrlSettings='q'
endif

" cheat sheet pager
if(!exists("g:CheatPager"))
    let g:CheatPager='less -R'
endif

" cheat sheet buffer name
if(!exists("g:CheatSheetBufferName"))
    let g:CheatSheetBufferName="_cheat"
endif

" Default selection (lines or word)
if(!exists("g:CheatSheetDefaultSelection"))
    let g:CheatSheetDefaultSelection="line"
endif

" Show comments in answers by default
if(!exists("g:CheatSheetShowCommentsByDefault"))
    let g:CheatSheetShowCommentsByDefault=1
endif

if(!exists("s:isNeovim"))
    redir => ver
    silent version
    redir END
    let s:isNeovim = (match(ver, 'NVIM')!=-1)
endif

let s:history=[]
let s:histPos=-1

let s:static_filetype = {
            \'c++': 'cpp'
            \}

" Returns the url to query
function! s:getUrl(query, asList)
    let url=g:CheatSheetBaseUrl.'/'.a:query
    let getter=g:CheatSheetUrlGetter." ".cheat#session#urloptions()
    if(a:asList==0)
        return getter." ".shellescape(url)
    endif
    return add(split(getter),url)
endfunction

" Print nice messages
function! cheat#echo(msg,type)
  if a:type=='e'
    let group='ErrorMsg'
  elseif a:type=='w'
    let group='WarningMsg'
  elseif a:type=='q'
    let group='Question'
  elseif a:type=='s'
    let group='Define'
  elseif a:type=='D'
    if !exists("g:CheatDebug")
      return
    else
      let group='WarningMsg'
    endif
  else
    let group='Normal'
  endif
  execute 'echohl '.group
  echo a:msg
  echohl None
endfunction

" Returns the list of available options
function! cheat#completeargs(A, L, P)
    call cheat#echo('Retrieving list of available cheat sheets', 'S')
    if(match(a:A, '.*/.*$')!=-1)
        let cat=substitute(a:A, '\(.*/\).*', '\1', '')
        let url=cat.':list'
    else
        let url=':list'
        let cat=''
    endif
    silent return substitute(system(s:getUrl(url, 0)),
                \'\(\n\|^\)\(\S\)', '\1'.cat.'\2', 'g')
endfunction

function! s:lastRequest()
    return s:history[s:histPos]
endfunction

" Lookup for previous or next answer (+- a:delta)
function! cheat#navigate(delta, type)
    if (! (a:delta =~# '^-\?\d\+$'))
        call cheat#echo('Delta must be a number', 'e')
        return
    endif

    if(s:histPos <0 || empty(s:lastRequest()))
        call cheat#echo('You must first call :Cheat or :CheatReplace', 'e')
        return
    endif

    " Move in history if required
    if(a:type=='H')
        let nextPos=s:histPos+a:delta
        if(nextPos<0)
            call cheat#echo('Cannot go into the future', 'e')
            return
        elseif(nextPos>=len(s:history))
            call cheat#echo('No more history', 'e')
            return
        endif
        let s:histPos=nextPos
        " Work directly on request from history, no copy
        let s:isInHistory=1
        let request = s:lastRequest()
    else
        " Retrieve request
        let s:isInHistory=0
        let request = copy(s:lastRequest())
    endif


    if(request.isCheatSheet == 1)
        call cheat#echo('Navigation is not implemented for cheat sheets', 'e')
        return
    endif

    " Change parameters
    if(a:type == 'Q')
        let request.q=max([0,request.q+a:delta])
        let request.a=0
        let request.s=0
    elseif(a:type == 'A')
        let request.a=max([0,request.a+a:delta])
        let request.s=0
    elseif(a:type == 'S')
        let request.s=max([0,request.s+a:delta])
    elseif(a:type == 'C')
        let request.comments=(request.comments+1)%2
    elseif(a:type !='H')
        call cheat#echo('Unknown navigation type "'.a:type.'"', 'e')
        return
    endif

    " Remove previously replaced lines
    if(request.mode == 1 || request.mode == 3 || request.mode == 4)
        let pos=request.appendpos+1
        execute ':'.pos
        execute 'd'.request.numLines
    endif

    let request.numLines=0
    call s:handleRequest(request)
endfunction

" Preprends ft and make sure that the query has a '+'
function! s:preparePlusQuery(query)
    let query=&ft.'/'.substitute(a:query, ' ', '+', 'g')
    " There must be a + in the query
    if(match(query, '+') == -1)
        let query=query.'+'
    endif
    return query
endfunction

" Completes request to be a high level request corresponding to the given
" query
function! s:requestFromQuery(query, request)
    let opts=split(a:query, '/')
    if(len(opts) >=3)
        let a:request.q=opts[2]
    else
        let a:request.q=0
    endif
    if(len(opts) >=4)
        " Remove see related if present
        let a:request.a=substitute(opts[3], '\(.*\),\+.*$', '\1', '')
    else
        let a:request.a=0
    endif
    " Remove see related uses , not /
    if(match(a:query, ',\d\+$')!=-1)
        let a:request.s=substitute(a:query, '^.*,\(\d\+\)$', '\1', '')
    else
        let a:request.s=0
    endif
    let a:request.ft=opts[0]
    let a:request.query=opts[0]."/".opts[1]
    if(match(a:query,'+')==-1)
        let a:request.isCheatSheet=1
    endif
    return a:request
endfunction

" Transforms a high level request into a query ready to be processed by cht.sh
function! s:queryFromRequest(request)
    let query=a:request.query
    if(a:request.isCheatSheet ==0)
        let query.='/'.a:request.q.'/'.a:request.a.','.a:request.s
    endif
    let query.='?'
    let query.=g:CheatSheetUrlSettings
    " Color pager requests
    if(a:request.mode!=2)
        let query.='T'
    endif
    if(a:request.comments==0)
        let query.='Q'
    endif
    if(exists("g:CheatSheetPagerStyle") && a:request.mode==2)
        let query.="&style=".g:CheatSheetPagerStyle
    endif
    return query
endfunction

" Prepare an empty request
function! s:initRequest()
    let request={}
    let request.a=0
    let request.q=0
    let request.s=0
    let request.comments=g:CheatSheetShowCommentsByDefault
    let request.ft=&ft
    let request["isCheatSheet"]=0
    let request.appendpos=0
    let request.numLines=0
    let request.mode=g:CheatSheetDefaultMode
    return request
endfunction

" Handle a cheat query
" Args :
"       query       : the text query
"       froml       : the first line (if no queries)
"       tol         : the last line (if no queries)
"       range       : the number of selected words in visual mode
"       mode        : the output mode : 0=> buffer, 1=> replace, 2=>pager,
"                       3=> paste after, 4 => paste before, 5 => error
"       isplusquery   : should we do a Ft query
function! cheat#cheat(query, froml, tol, range, mode, isplusquery) range
    if(a:mode ==2 && s:isNeovim == 1)
        call cheat#echo('Pager mode does not work with neovim'.
                    \' use <leader>KB instead', 'e')
        return
    endif
    let request=s:initRequest()
    if(a:mode == 5 )
        let query=cheat#providers#GetError()
        if(query == "")
            call cheat#echo("No error dectected, have you saved your buffer ?", 'w')
            return ""
        endif
    else
        if(a:query == "")
            let query=substitute(s:get_visual_selection(a:froml,a:tol, a:range),
                        \'^\s*', '', '')
        else
            let query=a:query
        endif
    endif

    if(a:isplusquery == '!')
        " No explicit query, prepare query from selection
        let request.query=s:preparePlusQuery(query)
    else
        " simple query
        let ft=substitute(query, '^/\?\([^/]*\)/.*$', '\1', '')
        if(ft == query)
            " simple query
            let request.ft=g:CheatSheetFt
            let request["isCheatSheet"]=1
            let request.query=query
        else
            " arbitrary query
            let request=s:requestFromQuery(query, request)
        endif
    endif

    " Reactivate history if required
    let s:isInHistory=0
    if(a:mode != 5)
        let request.mode=a:mode
    endif

    " Set append pos / remove query if required
    if(request.mode == 1)
        call cheat#echo('removing lines', 'e')
        normal dd
        let request.appendpos=getcurpos()[1]-1
    elseif(request.mode == 3)
        let request.appendpos=getcurpos()[1]
    elseif(request.mode == 4)
        let request.appendpos=getcurpos()[1]-1
    endif

    call s:handleRequest(request)
endfunction

" Prints a message about the query to be prossessed
function! s:displayRequestMessage(request)
    if(a:request.isCheatSheet == 1)
        let message='Looking for cheat sheet: "'.a:request.query.'" from '.
                    \g:CheatSheetBaseUrl
    else
        let message='Sending query : "'.a:request.query.'" to '.
                    \g:CheatSheetBaseUrl
        let more=''
        if(a:request.s!=0)
            let more.=", related number: ".a:request.s
        endif
        if(a:request.a!=0)
            let more.=", answer number: ".a:request.a
        endif
        if(a:request.q!=0)
            let more.=", question number: ".a:request.q
        endif
        if(more != '')
            let message.=" Requesting (".substitute(more,
                        \'^, ', '', '').")"
        endif
    endif
    call cheat#echo(message. " this may take some time", 'S')
endfunction

function! cheat#createOrSwitchToBuffer()
    let winnr = bufwinnr('^'.g:CheatSheetBufferName.'$')
    " Retrieve buffer or create it
    if ( winnr >= 0 )
        execute winnr . 'wincmd w'
    else
        execute ':'.g:CheatSheetReaderCmd.
                \ ' +set\ bt=nofile\ bufhidden=wipe '.
                \g:CheatSheetBufferName
        if(!exists("g:CheatSheetDoNotMap") || g:CheatSheetDoNotMap ==0)
            nnoremap <buffer> <silent> <localleader>h :call cheat#navigate(-1,'A')<CR>
            nnoremap <buffer> <silent> <localleader>j :call cheat#navigate(1,'Q')<CR>
            nnoremap <buffer> <silent> <localleader>k :call cheat#navigate(-1,'Q')<CR>
            nnoremap <buffer> <silent> <localleader>l :call cheat#navigate(1,'A')<CR>

            nnoremap <buffer> <silent> <localleader>H :call cheat#navigate(-1,'H')<CR>
            nnoremap <buffer> <silent> <localleader>J :call cheat#navigate(1,'S')<CR>
            nnoremap <buffer> <silent> <localleader>K :call cheat#navigate(-1,'S')<CR>
            nnoremap <buffer> <silent> <localleader>L :call cheat#navigate(1,'H')<CR>

        endif
    endif
endfunction

" Add request to history if not already in
function! s:saveRequest(request)
    if(s:isInHistory == 0 )
        let s:histPos+=1
        if(s:histPos < len(s:history))
            " We are back in history, remove meaning less nexts
            call remove(s:history, s:histPos, -1)
        endif
        call insert(s:history, a:request, s:histPos)
    endif
endfunction

" Launch the request with jobs if available
function! s:handleRequest(request)
    call s:saveRequest(a:request)
    let s:oldbuf=winnr()

    if(a:request.mode == 2)
        " Pager
        let curl=s:getUrl(s:queryFromRequest(a:request), 0)
        execute ":silent !".curl.' | '.g:CheatPager
        redraw!
        return
    elseif(a:request.mode == 0)
        " Prepare buffer
        call cheat#createOrSwitchToBuffer()
        execute 'normal ggdG'
        " Update ft
        if(has_key(s:static_filetype,a:request.ft))
            let ft=s:static_filetype[a:request.ft]
        else
            let ft=a:request.ft
        endif
        execute ': set ft='.ft
        execute s:oldbuf . 'wincmd w'
        redraw!
    endif

    call s:displayRequestMessage(a:request)
    let s:lines = []
    let has_job=!has('job')
    let curl=s:getUrl(s:queryFromRequest(a:request), has_job)
    if(has_job)
        " Asynchronous curl
        let s:job = job_start(curl,
                    \ {"callback": "cheat#handleRequestOutput",
                    \ "close_cb": "cheat#printAnswer"})
    else
        " Synchronous curl
        let s:lines=systemlist(curl)
        call cheat#printAnswer(0)
        redraw!
    endif
endfunction

function! cheat#printAnswer(channel)
    let request=s:lastRequest()
    if(request.mode == 0)
        call cheat#createOrSwitchToBuffer()
    endif
    call append(request.appendpos, s:lines)
    let request.numLines=len(s:lines)
    execute ':'.request.appendpos
    if(request.mode == 0)
        normal Gddgg
    endif
    execute s:oldbuf . 'wincmd w'
    " Clean stuff
    if(exists('s:job'))
        call job_stop(s:job)
        unlet s:job
    endif
    unlet s:lines
endfunction

" Read answer line by line
function! cheat#handleRequestOutput(channel, msg)
    if(a:msg == "DETACH")
        return
    endif
    call add(s:lines, a:msg)
endfunction

" Returns the text that is currently selected
function! s:get_visual_selection(froml, tol, range)
    " Why is this not a built-in Vim script function?!
    if(a:range<=0)
        if(g:CheatSheetDefaultSelection == "line")
            return join(getline(a:froml, a:tol), " ")
        else
            return expand("<cword>")
        endif
    endif
    "visual mode
    let [line_start, column_start] = getpos("'<")[1:2]
    let [line_end, column_end] = getpos("'>")[1:2]
    let lines = getline(line_start, line_end)
    if len(lines) == 0
        return ''
    endif
    let lines[-1] = lines[-1][: column_end - (&selection == 'inclusive' ? 1 : 2)]
    let lines[0] = lines[0][column_start - 1:]
    return join(lines, " ")
endfunction

function! cheat#toggleComments()
    let g:CheatSheetShowCommentsByDefault=(
                \g:CheatSheetShowCommentsByDefault+1)%2
    call cheat#echo('Setting comments to : '.g:CheatSheetShowCommentsByDefault,
                \ 'S')
endfunction

let cpo=save_cpo
" vim:set et sw=4:
