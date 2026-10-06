import {Editor} from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import Placeholder from '@tiptap/extension-placeholder';
import {Markdown} from '@tiptap/markdown';
import {createIcons,icons} from 'lucide';
import {createThemeManager} from './themes.js';
import {HighlightedCodeBlock} from './code-block.js';

const $=s=>document.querySelector(s), $$=s=>Array.from(document.querySelectorAll(s));
const native=window.webkit?.messageHandlers?.galpi;
const launcherMode=new URLSearchParams(location.search).has('launcher');
document.body.classList.toggle('is-launcher',launcherMode);
let library={notes:[],folders:[],preferences:{}},account={accounts:[],connected:false},selectedID=null,tab='memo',showTrash=false,loading=false;
let recording={active:false},playback={},saveTimer,toastTimer,launchIndex=0,launchItems=[],slashFrom=null,blockIndex=0;
const pending=new Map(),dirty=new Map(),inflight=new Map(),jobs=new Map();
let saving=Promise.resolve();
function icon(name){const i=document.createElement('i');i.dataset.lucide=name;i.setAttribute('aria-hidden','true');return i;}
function paintIcons(){createIcons({icons,attrs:{'stroke-width':1.6}});}
function el(tag,className,text){const e=document.createElement(tag);if(className)e.className=className;if(text!==undefined)e.textContent=text;return e;}
function button(label,fn,iconName){const b=el('button','',label);b.type='button';if(iconName)b.prepend(icon(iconName));b.addEventListener('click',()=>Promise.resolve(fn()).catch(error=>toast(error.message,true)));return b;}
function call(action,args={}){
  if(!native)return Promise.reject(new Error('Galpi.app에서 열어 주세요.'));
  return new Promise((resolve,reject)=>{const id=crypto.randomUUID();pending.set(id,{resolve,reject});native.postMessage({id,action,arguments:args});});
}
function toast(text,error=false){clearTimeout(toastTimer);$('#toast').textContent=text;$('#toast').classList.toggle('error',error);$('#toast').hidden=false;toastTimer=setTimeout(()=>$('#toast').hidden=true,error?12000:5000);}
function run(fn){return async()=>{try{await fn()}catch(error){toast(error.message,true)}};}
function note(){return library.notes.find(n=>n.id===selectedID);}
function stamp(seconds){const n=Math.max(0,Math.floor(seconds||0));return n>=3600?`${Math.floor(n/3600)}:${String(Math.floor(n/60)%60).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`:`${String(Math.floor(n/60)).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`;}
function queryMatch(text,query){return text.normalize('NFKC').toLocaleLowerCase().includes(query.normalize('NFKC').toLocaleLowerCase());}
const themes=createThemeManager({$, $$, call, run, toast, el, button, icon, paintIcons, getPreferences:()=>library.preferences});

const editor=new Editor({
  element:$('#editor'),
  extensions:[StarterKit.configure({codeBlock:false,heading:{levels:[1,2,3]},link:{openOnClick:false,HTMLAttributes:{rel:'noopener noreferrer'}}}),HighlightedCodeBlock,TaskList,TaskItem.configure({nested:true}),Placeholder.configure({placeholder:({node})=>node.type.name==='paragraph'?'생각을 적어보세요. / 로 블록을 추가할 수 있어요.':''}),Markdown.configure({markedOptions:{gfm:true}})],
  content:'',contentType:'markdown',
  editorProps:{attributes:{'aria-label':'메모 내용','spellcheck':'false'},handleKeyDown(view,event){
    if(event.isComposing)return false;
    if(!$('#block-menu').hidden&&['ArrowDown','ArrowUp','Enter'].includes(event.key)){
      const items=$$('[data-block]');if(event.key==='Enter')items[blockIndex].click();else{blockIndex=(blockIndex+(event.key==='ArrowDown'?1:-1)+items.length)%items.length;items.forEach((b,i)=>b.classList.toggle('selected',i===blockIndex));}return true;
    }
    const cursor=view.state.selection.$from;
    if(event.key==='/'&&!event.metaKey&&!event.ctrlKey&&cursor.parent.type.name==='paragraph'&&cursor.parent.textContent.length===0){slashFrom=view.state.selection.from;blockIndex=0;$$('[data-block]').forEach((b,i)=>b.classList.toggle('selected',i===0));$('#block-menu').hidden=false;return true;}
    if(event.key==='Escape'&&!$('#block-menu').hidden){$('#block-menu').hidden=true;return true;}
    return false;
  }},
  onUpdate(){if(loading)return;const n=note();if(!n)return;const markdown=editor.getMarkdown();const payload=tab==='memo'?{markdown,document:JSON.stringify(editor.getJSON())}:{[tab]:markdown};queueSave(payload);renderNoteList();},
  onSelectionUpdate(){const {from,to}=editor.state.selection;$('#format-toolbar').hidden=from===to||!editor.isFocused;},
  onBlur(){setTimeout(()=>{if(!$('#format-toolbar').contains(document.activeElement))$('#format-toolbar').hidden=true;},150)}
});
function queueSave(payload){if(!selectedID)return;Object.assign(note(),payload);dirty.set(selectedID,{...dirty.get(selectedID),...payload});$('#save-status').textContent='저장 중…';clearTimeout(saveTimer);saveTimer=setTimeout(()=>flushSave().catch(e=>toast(e.message,true)),250);}
function flushSave(){
  clearTimeout(saveTimer);
  saving=saving.catch(()=>{}).then(async()=>{
    const batch=Array.from(dirty.entries());dirty.clear();
    for(const[id,payload]of batch)inflight.set(id,payload);
    for(let i=0;i<batch.length;i++){
      const[id,payload]=batch[i];
      try{await call('save',{noteID:id,...payload});inflight.delete(id);}
      catch(error){for(const[remainingID,remaining]of batch.slice(i)){dirty.set(remainingID,{...remaining,...dirty.get(remainingID)});inflight.delete(remainingID);}$('#save-status').textContent='저장 실패 · 다시 시도';throw error;}
    }
    if(dirty.size===0)$('#save-status').textContent='내 맥에 저장됨';
  });return saving;
}
function mergeState(incoming){
  for(const n of incoming.notes)Object.assign(n,inflight.get(n.id),dirty.get(n.id));
  library=incoming;document.body.classList.toggle('is-compact',!!library.preferences.compact);
  themes.sync();
  $('#always-top').setAttribute('aria-pressed',String(!!library.preferences.alwaysOnTop));
  $('#compact').setAttribute('aria-pressed',String(!!library.preferences.compact));
  renderNoteList();renderFolders();renderAttachments();renderLauncher();
  if(selectedID&&!note())selectNote(library.notes.find(n=>!n.deleted)?.id).catch(e=>toast(e.message,true));
}
async function selectNote(id){
  if(!id){$('#note-page').hidden=true;return;}
  await flushSave();
  const fresh=await call('select',{noteID:id});
  const index=library.notes.findIndex(n=>n.id===id);if(index>=0)library.notes[index]=fresh;else library.notes.unshift(fresh);
  selectedID=id;tab='memo';showNote();renderNoteList();
}
function showNote(){
  const n=note();$('#note-page').hidden=!n;if(!n)return;
  loading=true;$('#note-title').value=n.title==='제목 없는 메모'?'':n.title;
  $('#note-title').disabled=n.deleted;
  $('#note-date').textContent=new Date(n.created*1000).toLocaleDateString('ko-KR',{month:'long',day:'numeric',weekday:'long'});
  $('#category').replaceChildren(icon(n.recordings.length?'notebook-pen':'sticky-note'),document.createTextNode(n.recordings.length?'회의 메모':'개인 메모'));
  $('#note-pin').setAttribute('aria-pressed',String(n.pinned));
  $('#trash').setAttribute('aria-label',n.deleted?'메모 복원':'메모 보관');
  const content=tab==='memo'?n.markdown:n[tab]||'';
  try{if(tab==='memo'&&n.document)editor.commands.setContent(JSON.parse(n.document),{emitUpdate:false});else editor.commands.setContent(content,{contentType:'markdown',emitUpdate:false});}
  catch{editor.commands.setContent(content,{contentType:'markdown',emitUpdate:false});}
  loading=false;
  $$('[data-tab]').forEach(b=>b.classList.toggle('selected',b.dataset.tab===tab));
  renderEditorState();renderAttachments();paintIcons();
}
function renderEditorState(){
  const n=note();if(!n)return;const job=jobs.get(n.id);
  $('#job').hidden=!job;$('#job-text').textContent=job||'';
  const editable=!n.deleted&&!(job&&tab!=='memo');
  if(editor.isEditable!==editable)editor.setEditable(editable,false);
  $$('.code-language').forEach(select=>select.disabled=!editable);
  $('#summary-empty').hidden=!(tab==='summary'&&!n.summary&&!job);
  $('#editor').hidden=tab==='summary'&&!n.summary&&!job;
  $('.block-insert').hidden=$('#editor').hidden||n.deleted;
  $('#transcript-hint').hidden=tab!=='transcript'||!!n.transcript;
  $('#transcribe').hidden=tab!=='transcript';$('#generate').hidden=tab!=='summary'||!n.summary;
  for(const id of ['#transcribe','#generate','#generate-empty'])$(id).disabled=!!job||n.deleted||recording.noteID===n.id;
  $('#record-open').disabled=recording.active||n.deleted;
}
function renderNoteList(){
  const list=$('#note-list');list.replaceChildren();const q=$('#note-query').value.trim();
  const filtered=library.notes.filter(n=>!!n.deleted===showTrash&&queryMatch(n.title+' '+n.markdown+' '+n.summary+' '+n.transcript,q)).sort((a,b)=>Number(b.pinned)-Number(a.pinned)||b.updated-a.updated);
  if(!filtered.length)list.append(el('div','list-empty',q?'찾는 메모가 없어요.':showTrash?'보관한 메모가 없어요.':'새 메모를 만들어보세요.'));
  let section='';
  for(const n of filtered){const next=showTrash?'보관한 메모':n.pinned?'고정한 메모':'최근 메모';if(next!==section){section=next;list.append(el('div','list-label',section));}
    const row=button('',()=>selectNote(n.id));row.className='note-item'+(n.id===selectedID?' selected':'');row.append(icon(n.recordings.length?'audio-lines':'file-text'));
    const copy=el('span','copy');copy.append(el('span','name',n.title),el('small','',n.markdown.replace(/[#*`>\[\]]/g,'').replace(/\n/g,' ').slice(0,65)||'내용 없음'));row.append(copy);list.append(row);
  }paintIcons();
}
function renderAttachments(){
  const list=$('#attachments');list.replaceChildren();const n=note();if(!n)return;
  n.recordings.filter(r=>r.status!=='recording').forEach((r,index)=>{
    const row=el('div','attachment');row.dataset.recording=r.id;row.append(icon('audio-lines'));
    const copy=el('div','audio-copy');copy.append(el('span','',`녹음 ${index+1}`),el('small','',r.status==='failed'?'녹음 시작 실패':r.status==='interrupted'?'중단된 녹음 · 저장된 파일 보존':stamp(r.duration)));row.append(copy);
    if(r.tracks.length){const play=button('',()=>call('play',{noteID:n.id,recordingID:r.id}),'play');play.setAttribute('aria-label','녹음 재생 또는 일시정지');row.append(play);const range=el('input');range.type='range';range.min='0';range.max=String(r.duration||1);range.step='0.1';range.value='0';range.setAttribute('aria-label','녹음 재생 위치');range.addEventListener('change',run(()=>call('seek',{seconds:Number(range.value)})));row.append(range);}
    const folder=button('',()=>call('revealRecording',{noteID:n.id,recordingID:r.id}),'folder-open');folder.setAttribute('aria-label','녹음 파일 보기');row.append(folder);list.append(row);
  });paintIcons();
}
function setRecording(data){
  recording=data;$('#recording-bar').hidden=!data.active;$('#record-time').textContent=stamp(data.duration);$('#record-label').textContent=data.paused?'녹음 일시정지':data.noteID===selectedID?'녹음 중':'다른 메모 녹음 중';$('#pause-record').textContent=data.paused?'계속 녹음':'일시정지';renderEditorState();
}
function setPlayback(data){
  playback=data;
  for(const row of $$('.attachment')){
    const active=row.dataset.recording===data.id,range=row.querySelector('input[type=range]');
    if(range){range.disabled=!active;if(active){range.max=String(data.duration||1);if(document.activeElement!==range)range.value=String(data.time||0);}}
    const b=row.querySelector('button');if(b&&range){const name=active&&data.playing?'pause':'play';if(b.dataset.icon!==name){b.replaceChildren(icon(name));b.dataset.icon=name;}}
  }paintIcons();
}
function renderFolders(){
  $('#launcher-key').textContent=library.preferences.launcher?.label||'단축키 설정';
  const list=$('#folder-list');list.replaceChildren();
  if(!library.folders.length)list.append(el('p','fine','자주 여는 폴더를 등록해보세요.'));
  library.folders.forEach(f=>{
    const row=el('div','folder-row'),head=el('div','folder-head');head.append(icon('folder'));
    const name=el('input');name.value=f.name;name.setAttribute('aria-label','폴더 이름');name.addEventListener('change',run(()=>call('renameFolder',{folderID:f.id,name:name.value})));head.append(name);row.append(head,el('div','folder-path',f.path));
    const actions=el('div','folder-actions');const key=button(f.shortcut?.label||'단축키 지정',()=>captureShortcut(f.id));key.className='key-button';actions.append(key);
    if(f.shortcut)actions.append(button('해제',()=>call('clearShortcut',{folderID:f.id})));
    actions.append(button('열기',()=>call('openFolder',{folderID:f.id})),button('등록 해제',()=>call('removeFolder',{folderID:f.id})));row.append(actions);list.append(row);
  });paintIcons();
}
async function captureShortcut(folderID){$('#shortcut-dialog').hidden=false;try{await call('shortcut',folderID?{folderID}:{});}finally{$('#shortcut-dialog').hidden=true;}}
function settings(panel='folders'){
  $('#settings').hidden=false;
  $$('[data-settings]').forEach(b=>b.classList.toggle('selected',b.dataset.settings===panel));
  $$('[data-settings-panel]').forEach(p=>p.hidden=p.dataset.settingsPanel!==panel);
  if(panel==='ai'){renderAccount();loadLocales();if(account.connected)loadModels().catch(e=>toast(e.message,true));}
}
function renderAccount(){
  const list=$('#account-list');list.replaceChildren();
  if(account.accounts.length){const select=el('select');select.setAttribute('aria-label','ChatGPT 계정');account.accounts.forEach(a=>{const o=el('option','',`${a.email} · ${a.id.slice(-6)}${a.connected?'':' · 다시 연결 필요'}`);o.value=a.id;select.append(o)});select.value=account.selected;select.addEventListener('change',run(async()=>{await call('selectAccount',{accountID:select.value});await loadModels()}));list.append(select);}
  $('#sign-out').hidden=!account.connected;$('#sign-in').textContent=account.connected?'다른 ChatGPT 계정 추가':'Continue with ChatGPT';$('#cancel-login').hidden=!account.signingIn;$('#sign-in').disabled=Boolean(account.signingIn);
}
async function loadModels(){
  if(!account.connected)return;
  const clientID=account.selected;
  const models=await call('models');if(!account.connected||account.selected!==clientID)return;
  const select=$('#model');select.replaceChildren();select.append(new Option('모델 선택',''));
  models.forEach(m=>select.append(new Option(m.name,m.id)));select.value=library.preferences.model||'';
}
let localesLoaded=false;
async function loadLocales(){
  if(localesLoaded)return;
  try{const locales=await call('locales');const select=$('#locale');const current=library.preferences.locale||'ko-KR';select.replaceChildren();
    const sorted=Array.from(new Set([current,...locales]));sorted.forEach(code=>{const o=new Option(`${code}${locales.includes(code)?'':' · 지원 확인 필요'}`,code);select.append(o)});select.value=current;$('#locale-status').textContent=locales.length?`이 Mac에서 사용 가능한 언어 ${locales.length}개`:'사용 가능한 음성 언어를 확인하지 못했어요.';localesLoaded=true;
  }catch(e){$('#locale-status').textContent=e.message;}
}
async function doJob(action){
  await flushSave();const n=note();if(!n)return;
  if(action==='summarize'&&(!account.connected||!library.preferences.model)){settings('ai');toast('ChatGPT 계정과 회의록 모델을 설정해 주세요.');return;}
  const id=n.id;jobs.set(id,action==='transcribe'?'음성 변환 준비 중…':'회의록 생성 준비 중…');renderEditorState();
  try{const updated=await call(action,{noteID:id});const i=library.notes.findIndex(n=>n.id===id);if(i>=0)library.notes[i]=updated;if(selectedID===id){tab=action==='transcribe'?'transcript':'summary';showNote();}}
  finally{jobs.delete(id);renderEditorState();}
}
function openLauncher(){$('#launcher').hidden=false;$('#launcher-query').value='';launchIndex=0;renderLauncher();setTimeout(()=>$('#launcher-query').focus(),50);}
function closeLauncher(){$('#launcher').hidden=true;if(launcherMode)call('hideLauncher').catch(()=>{});}
function renderLauncher(){
  if($('#launcher').hidden)return;
  const q=$('#launcher-query').value.trim();launchItems=[];
  if(!q||queryMatch('새 메모 만들기',q))launchItems.push({title:'새 메모',sub:'바로 쓰기 시작',icon:'square-pen',action:()=>call('create')});
  for(const n of library.notes.filter(n=>!n.deleted&&queryMatch(n.title+' '+n.markdown+' '+n.summary,q)).sort((a,b)=>Number(b.pinned)-Number(a.pinned)||b.updated-a.updated).slice(0,7))launchItems.push({title:n.title,sub:'메모',icon:'file-text',action:()=>launcherMode?call('select',{noteID:n.id}):selectNote(n.id)});
  for(const f of library.folders.filter(f=>queryMatch(f.name+' '+f.path,q)))launchItems.push({title:f.name,sub:f.path,icon:'folder',shortcut:f.shortcut?.label,action:()=>call('openFolder',{folderID:f.id})});
  if(!q||queryMatch('설정 단축키 ChatGPT 폴더',q))launchItems.push({title:'설정',sub:'폴더, 단축키, ChatGPT',icon:'settings-2',action:()=>launcherMode?call('settings'):settings()});
  launchIndex=Math.max(0,Math.min(launchIndex,launchItems.length-1));
  const list=$('#launcher-results');list.replaceChildren();if(!launchItems.length)list.append(el('div','list-empty','검색 결과가 없어요.'));
  launchItems.forEach((item,index)=>{const row=button('',async()=>{await flushSave();await item.action();closeLauncher();});row.className='launch-result'+(index===launchIndex?' selected':'');row.append(icon(item.icon));const copy=el('div','launch-copy');copy.append(el('span','',item.title),el('small','',item.sub));row.append(copy);if(item.shortcut)row.append(el('kbd','',item.shortcut));list.append(row);});paintIcons();
}
async function init(){
  try{const result=await call('ready');library=result.library;account=result.account;$('#data-path').textContent=result.dataPath;mergeState(library);renderAccount();
    if(launcherMode){openLauncher();}else{await selectNote(library.selectedNoteID||library.notes.find(n=>!n.deleted)?.id);}
    if(result.notices.length)toast(result.notices.join('\n'),true);
  }catch(e){toast(e.message,true);}
}
window.Galpi={
  flush(){flushSave().catch(e=>toast(e.message,true));return true;},
  flushAsync:flushSave,
  receive(message){
    if(message.id){const promise=pending.get(message.id);if(!promise)return;pending.delete(message.id);message.error?promise.reject(new Error(message.error)):promise.resolve(message.result);return;}
    const d=message.data;
    switch(message.event){
      case 'state':mergeState(d);break;
      case 'select':if(!launcherMode)selectNote(d.id).catch(e=>toast(e.message,true));break;
      case 'settings':if(!launcherMode)settings();break;
      case 'launcher':openLauncher();break;
      case 'notice':toast(d.message,d.error);break;
      case 'account':{const changed=account.selected!==d.selected||account.connected!==d.connected;account=d;renderAccount();if(changed){$('#model').replaceChildren(new Option('모델 선택',''));if(account.connected)loadModels().catch(e=>toast(e.message,true));}break;}
      case 'recording':setRecording(d);break;
      case 'playback':setPlayback(d);break;
      case 'job':d.busy?jobs.set(d.noteID,d.message):jobs.delete(d.noteID);renderEditorState();break;
    }
  }
};

$('#note-title').addEventListener('input',()=>{queueSave({title:$('#note-title').value});renderNoteList();});
$('#note-query').addEventListener('input',renderNoteList);
$('#save-status').addEventListener('click',run(flushSave));
$('#create').onclick=run(async()=>{await flushSave();await call('create');});
$('#note-pin').onclick=run(async()=>{await flushSave();await call('pin',{noteID:selectedID});$('#note-pin').setAttribute('aria-pressed',String(note()?.pinned));});
$('#trash').onclick=run(async()=>{await flushSave();const n=note();if(!n)return;await call(n.deleted?'restore':'trash',{noteID:n.id});const next=library.notes.find(x=>!!x.deleted===showTrash);if(next)await selectNote(next.id);else{selectedID=null;$('#note-page').hidden=true;}});
$('#trash-view').onclick=run(async()=>{await flushSave();showTrash=!showTrash;$('#trash-view').classList.toggle('selected',showTrash);renderNoteList();await selectNote(library.notes.find(n=>!!n.deleted===showTrash)?.id);});
$('#export').onclick=run(async()=>{await flushSave();await call('export',{noteID:selectedID,field:tab});});
$('#import').onclick=run(async()=>{await flushSave();await call('import');});
$('#compact').onclick=run(()=>call('compact'));
$('#always-top').onclick=run(()=>call('top'));
$('#search-open').onclick=openLauncher;
$('#settings-open').onclick=()=>settings();$('#settings-close').onclick=()=>$('#settings').hidden=true;
$$('[data-settings]').forEach(b=>b.onclick=()=>settings(b.dataset.settings));
$$('[data-tab]').forEach(b=>b.onclick=run(async()=>{await flushSave();tab=b.dataset.tab;showNote();}));
$('#block-add').onmousedown=e=>e.preventDefault();$('#block-add').onclick=()=>{slashFrom=null;$('#block-menu').hidden=!$('#block-menu').hidden;};
$$('[data-block]').forEach(b=>{b.onmousedown=e=>e.preventDefault();b.onclick=()=>{let chain=editor.chain().focus();if(slashFrom!==null)chain=chain.setTextSelection(slashFrom);const type=b.dataset.block;const methods={paragraph:'setParagraph',task:'toggleTaskList',bullet:'toggleBulletList',quote:'toggleBlockquote',code:'toggleCodeBlock'};if(type==='heading')chain.toggleHeading({level:2}).run();else chain[methods[type]]().run();$('#block-menu').hidden=true;slashFrom=null;};});
$$('[data-format]').forEach(b=>{b.onmousedown=e=>e.preventDefault();b.onclick=run(async()=>{const type=b.dataset.format;if(type==='link'){const result=await call('link',{url:editor.getAttributes('link').href||''});if(result.cancelled)return;const chain=editor.chain().focus().extendMarkRange('link');result.url?chain.setLink({href:result.url}).run():chain.unsetLink().run();}else{const commands={bold:'toggleBold',italic:'toggleItalic',strike:'toggleStrike',code:'toggleCode'};editor.chain().focus()[commands[type]]().run();}});});
$('#record-open').onclick=()=>$('#record-dialog').hidden=false;$('#record-cancel').onclick=()=>$('#record-dialog').hidden=true;
$('#record-start').onclick=run(async()=>{await flushSave();$('#record-start').disabled=true;try{await call('record',{noteID:selectedID,mode:$('input[name=record-mode]:checked').value});$('#record-dialog').hidden=true;}finally{$('#record-start').disabled=false;}});
$('#pause-record').onclick=run(()=>call('pause'));$('#stop-record').onclick=run(async()=>{$('#stop-record').disabled=true;try{await call('stop');}finally{$('#stop-record').disabled=false;}});
$('#transcribe').onclick=run(()=>doJob('transcribe'));$('#generate').onclick=$('#generate-empty').onclick=run(()=>doJob('summarize'));$('#connect-empty').onclick=()=>settings('ai');
$('#folder-add').onclick=run(()=>call('addFolder'));$('#launcher-key').onclick=run(()=>captureShortcut());$('#shortcut-cancel').onclick=run(()=>call('cancelShortcut'));
$('#sign-in').onclick=run(async()=>{const existing=!account.connected?account.selected:undefined;$('#sign-in').disabled=true;try{await call('signIn',existing?{accountID:existing}:{});}catch(error){$('#sign-in').disabled=false;throw error;}});
$('#cancel-login').onclick=run(async()=>{await call('cancelLogin');account.signingIn=false;renderAccount();});
$('#sign-out').onclick=run(()=>call('signOut'));$('#reload-models').onclick=run(loadModels);
$('#model').onchange=run(()=>call('preferences',{model:$('#model').value}));$('#locale').onchange=run(()=>call('preferences',{locale:$('#locale').value}));
$('#data-folder').onclick=run(()=>call('dataFolder'));
$('#launcher-query').oninput=()=>{launchIndex=0;renderLauncher();};
$('#launcher-query').addEventListener('keydown',e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();launchIndex=Math.max(0,Math.min(launchItems.length-1,launchIndex+(e.key==='ArrowDown'?1:-1)));renderLauncher();$('#launcher-results .selected')?.scrollIntoView({block:'nearest'});}if(e.key==='Enter'){e.preventDefault();$('#launcher-results .selected')?.click();}});
document.addEventListener('keydown',e=>{if(e.isComposing)return;if(e.key==='Escape'){if(!$('#theme-dialog').hidden){themes.cancel();return;}if(!$('#shortcut-dialog').hidden)return;if(!$('#block-menu').hidden){$('#block-menu').hidden=true;return;}if(!$('#launcher').hidden){closeLauncher();return;}$('#settings').hidden=true;$('#record-dialog').hidden=true;}if((e.metaKey||e.ctrlKey)&&e.key==='s'){e.preventDefault();flushSave().catch(e=>toast(e.message,true));}});
document.addEventListener('click',e=>{if(!$('.block-insert').contains(e.target)&&!$('#editor').contains(e.target))$('#block-menu').hidden=true;});
paintIcons();init();
