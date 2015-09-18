" searchindex.vim - display current & total number of search matches
" Author: Radoslaw Burny (rburny@google.com)
"
" Copyright 2015 Google Inc. All rights reserved.
"
" Licensed under the Apache License, Version 2.0 (the "License");
" you may not use this file except in compliance with the License.
" You may obtain a copy of the License at
"
"     http://www.apache.org/licenses/LICENSE-2.0
"
" Unless required by applicable law or agreed to in writing, software
" distributed under the License is distributed on an "AS IS" BASIS,
" WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
" See the License for the specific language governing permissions and
" limitations under the License.

if exists('g:loaded_searchindex') || &cp || v:version < 700
  finish
endif
let g:loaded_searchindex = 1

" Setup options.
if !exists('g:searchindex_line_limit')
  let g:searchindex_line_limit=1000000
endif

if !exists('g:searchindex_improved_star')
  let g:searchindex_improved_star=1
endif

if !exists('g:searchindex_star_case')
  let g:searchindex_star_case=1
endif

" New command and mappings: show search index of last search pattern at
" the current cursor position.
command! -bar SearchIndex call <SID>PrintMatches()

if !hasmapto('<Plug>SearchIndex', 'n')
  nmap <silent> g/ <Plug>SearchIndex
endif

noremap  <Plug>SearchIndex <Nop>
noremap! <Plug>SearchIndex <Nop>
nnoremap <Plug>SearchIndex :call <SID>PrintMatches()<CR>

" Remap search commands.
nmap <silent>n  n<Plug>SearchIndex
nmap <silent>N  N<Plug>SearchIndex

map <expr> *  <SID>StarSearch('*')
map <expr> #  <SID>StarSearch('#')
map <expr> g* <SID>StarSearch('g*')
map <expr> g# <SID>StarSearch('g#')

" Remap searches from '/' and 'g/' by plugging into <CR> in cmdline & cmdwin.
cmap <silent> <expr> <CR> <SID>handle_cr()
function! s:handle_cr()
  if getcmdtype() =~ '[/?]'
    return "\<CR>\<Plug>SearchIndex"
  else
    return "\<CR>"
  endif
endfunction

augroup searchindex_cmdwin
  autocmd!
  autocmd CmdWinEnter *
    \ if getcmdwintype() =~ '[/?]' |
    \   nmap <silent> <buffer> <CR> <CR><Plug>SearchIndex|
    \ endif
augroup END

" Implementation details.

function! s:StarSearch(cmd)
  if !g:searchindex_improved_star
    " show search index after command, but don't change its behavior
    return a:cmd . "\<Plug>SearchIndex"
  endif

  " With no word under cursor, search will fail. Fall back to '*' so that
  " error seems to come from native Vim command, not from this function.
  if expand("<cword>") == "" | return "*" | endif

  " reimplement star commands using '/' and '?'
  let search_dir = (a:cmd == '*' || a:cmd == 'g*') ? '/' : '?'
  let case_char = (g:searchindex_star_case ? '\C' : '\c')
  let [open_delim, close_delim] = (a:cmd =~ 'g.' ? ['', ''] : ['\<', '\>'])
  let search_term = open_delim . "\<C-R>\<C-W>" . close_delim
  return search_dir . search_term . case_char . "\<CR>"
endfunction

function! s:MatchesInRange(range)
  let gflag = &gdefault ? '' : 'g'
  let output = ''
  redir => output
    silent! execute a:range . 's///en' . gflag
  redir END
  return str2nr(matchstr(output, '\d\+'))
endfunction

" Calculate which match in the current line the 'col' is at.
function! s:MatchInLine()
  let line = line('.')
  let col = col('.')
  let star_search = 0

  normal 0
  let matches = 0
  let s_opt = 'c'
  " The count might be off in edge cases (e.g. regexes that allow empty match,
  " like 'a*'). Unfortunately, Vim's searching functions are so inconsistent
  " that I can't fix this.
  while search(@/, s_opt, line) && col('.') <= col
    let matches += 1
    let s_opt = ''
  endwhile

  return matches
endfunction

" Efficiently recalculate number of matches above cursor using values cached
" from the previous run.
function s:MatchesAbove(cached_values)
  " avoid wrapping range at the beginning of file
  if line('.') == 1 | return 0 | endif

  let [old_line, old_result, total] = a:cached_values
  " Find the nearest point from which we can restart match counting (top,
  " bottom, or previously cached line).
  let line = line('.')
  let to_top = line
  let to_old = abs(line - old_line)
  let to_bottom = line('$') - line
  let min_dist = min([to_top, to_old, to_bottom])

  if min_dist == to_top
    return s:MatchesInRange('1,.-1')
  elseif min_dist == to_bottom
    return total - s:MatchesInRange(',$')
  " otherwise, min_dist == to_old, we just need to check relative line order
  elseif old_line < line
    return old_result + s:MatchesInRange(old_line . ',-1')
  elseif old_line > line
    return old_result - s:MatchesInRange(',' . (old_line - 1))
  else " old_line == line
    return old_result
  endif
endfunction

function! s:PrintMatches()
  let dir_char = v:searchforward ? '/' : '?'
  if line('$') > g:searchindex_line_limit
    echo '[MAX]  ' . dir_char . @/
    return
  endif

  let [current, total] = searchindex#MatchCounts()
  if total != 0
    echo '[' . current . '/' . total . ']  ' . dir_char . @/
  endif
endfunction

" Return 2-element array, containing current index and total number of matches
" of @/ (last search pattern) in the current buffer.
function! searchindex#MatchCounts()
  " both :s and search() modify cursor position
  let win_view = winsaveview()

  let in_line = s:MatchInLine()

  let cache_key = [b:changedtick, @/]
  if exists('b:searchindex_cache_key') && b:searchindex_cache_key ==# cache_key
    let before = s:MatchesAbove(b:searchindex_cache_val)
    let total = b:searchindex_cache_val[-1]
  else
    let before = (line('.') == 1 ? 0 : s:MatchesInRange('1,-1'))
    let total = before + s:MatchesInRange(',$')
  endif

  let b:searchindex_cache_val = [line('.'), before, total]
  let b:searchindex_cache_key = cache_key

  call winrestview(win_view)

  return [before + in_line, total]
endfunction

""" IMPLEMENTATION NOTES

""" SEARCH TRIGGER
" It's tricky to detect when search is done precisely. We achieve this with
" two-level mappings:
" * conditional mapping of <CR> in cmdline / cmdwin. It checks command type to
"   only add <Plug>SearchIndex after search, not ex command or anything else.
" * mode-specific remappings of said <Plug> command that only display search
"   index in normal mode
" This way, if user performs search in non-normal mode, we don't clobber it
" (we could consider showing index in visual when noshowmode is set).
"
""" STAR COMMANDS OVERRIDE
" One Vim's quirk is that '*' and '#' commands silently ignore smartcase
" option. This is not detectable, which makes it impossible to count number of
" matches after 'star' commands correctly.
" Instead of hacking around this problem, we provide our own implementations
" of star commands. Additional advantage is that their case-sensitiveness can
" be controlled with a new option.
"
""" CACHING
" To improve efficiency, we cache results of last counting. This makes 'n'
" super fast. We only cache linewise counts, and in-line part is always
" recalculated. This prevents counting error from building up after multiple
" searches if in-line count was imprecise (which happens with regex searches).
