const palettes={
  light:{paper:'#fffefd',side:'#f5f4f1',ink:'#2c2c2a',dim:'#77766f',line:'#e6e4de',blue:'#526782'},
  dark:{paper:'#222222',side:'#292927',ink:'#eeede9',dim:'#aaa9a1',line:'#3d3c38',blue:'#acc0da'}
};
const labels={paper:'배경',side:'사이드바',ink:'글자',dim:'보조 글자',line:'구분선',blue:'강조색'};
const validHex=value=>/^#[0-9a-f]{6}$/i.test(value);
function darkColor(hex){const rgb=parseInt(hex.slice(1),16);return .2126*(rgb>>16&255)+.7152*(rgb>>8&255)+.0722*(rgb&255)<140;}
function mix(a,b,amount){const x=parseInt(a.slice(1),16),y=parseInt(b.slice(1),16);return '#'+[16,8,0].map(shift=>Math.round((x>>shift&255)*(1-amount)+(y>>shift&255)*amount).toString(16).padStart(2,'0')).join('');}
function colorStyles(element,colors){
  for(const key of [...Object.keys(labels),'hover','warm'])element.style.removeProperty('--'+key);
  if(!colors)return;
  for(const key of Object.keys(labels))element.style.setProperty('--'+key,colors[key]);
  element.style.setProperty('--hover',mix(colors.side,colors.ink,.09));
  element.style.setProperty('--warm',mix(colors.paper,colors.blue,.12));
}

export function createThemeManager({$, $$, call, run, toast, el, button, icon, paintIcons, getPreferences}){
  let draft=null,busy=false;
  function themes(){return getPreferences().customThemes||[];}
  function sync(){
    const selected=getPreferences().theme||'system',custom=themes().find(t=>t.id===selected);
    document.documentElement.dataset.theme=custom?(custom.isDark?'dark':'light'):['light','dark'].includes(selected)?selected:'system';
    document.documentElement.dataset.themeId=selected;
    colorStyles(document.documentElement,custom?.colors);
    $$('[data-theme-choice]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.themeChoice===selected)));
    const list=$('#custom-themes');list.replaceChildren();
    if(!themes().length)list.append(el('p','fine','좋아하는 색으로 첫 테마를 만들어보세요.'));
    for(const theme of themes()){
      const card=el('div','custom-theme-card');card.dataset.themeId=theme.id;
      const choose=button('',()=>call('preferences',{theme:theme.id}));choose.className='custom-theme-choice';choose.setAttribute('aria-pressed',String(theme.id===selected));choose.setAttribute('aria-label',theme.name+' 테마 적용');
      const swatches=el('span','theme-swatches');for(const key of ['paper','side','ink','blue']){const dot=el('span');dot.style.backgroundColor=theme.colors[key];swatches.append(dot);}
      choose.append(swatches,el('span','theme-name',theme.name));card.append(choose);
      const actions=el('div','theme-card-actions');
      const edit=button('수정',()=>begin(theme), 'pencil');edit.dataset.themeEdit=theme.id;edit.setAttribute('aria-label',theme.name+' 테마 수정');
      const exp=button('',()=>call('exportTheme',{themeID:theme.id}),'download');exp.setAttribute('aria-label',theme.name+' 테마 내보내기');
      const remove=button('',()=>call('removeTheme',{themeID:theme.id}),'trash-2');remove.setAttribute('aria-label',theme.name+' 테마 삭제');
      actions.append(edit,exp,remove);card.append(actions);list.append(card);
    }
    paintIcons();
  }
  function begin(existing){
    const current=themes().find(t=>t.id===getPreferences().theme);
    const dark=document.documentElement.dataset.theme==='dark'||(document.documentElement.dataset.theme==='system'&&matchMedia('(prefers-color-scheme: dark)').matches);
    draft={id:existing?.id,name:existing?.name||'',colors:{...(existing?.colors||current?.colors||palettes[dark?'dark':'light'])}};
    $('#theme-editor-title').textContent=existing?'테마 수정':'새 테마';$('#theme-name').value=draft.name;
    renderFields();$('#theme-dialog').hidden=false;$('#theme-name').focus();
  }
  function renderFields(){
    const fields=$('#theme-fields');fields.replaceChildren();
    for(const[key,label]of Object.entries(labels)){
      const row=el('div','theme-field'),title=el('label','',label);title.htmlFor='theme-hex-'+key;
      const controls=el('div','theme-color-inputs'),picker=el('input'),hex=el('input');
      picker.type='color';picker.value=draft.colors[key];picker.setAttribute('aria-label',label+' 색 고르기');picker.dataset.themeColor=key;
      hex.type='text';hex.id='theme-hex-'+key;hex.value=draft.colors[key];hex.maxLength=7;hex.spellcheck=false;hex.setAttribute('aria-label',label+' 색상 코드');hex.autocomplete='off';hex.dataset.themeHex=key;
      picker.addEventListener('input',()=>{draft.colors[key]=picker.value;hex.value=picker.value;preview();});
      hex.addEventListener('input',()=>{if(validHex(hex.value)){draft.colors[key]=hex.value.toLowerCase();picker.value=hex.value;}preview();});
      controls.append(picker,hex);row.append(title,controls);fields.append(row);
    }
    preview();
  }
  function preview(){
    if(!draft)return;
    draft.name=$('#theme-name').value.trim();
    const invalid=$$('[data-theme-hex]').some(input=>!validHex(input.value));
    $('#theme-save').disabled=busy||!draft.name||invalid;
    $('#theme-validation').textContent=invalid?'색상 코드를 #123456 형태로 입력해 주세요.':!draft.name?'테마 이름을 입력해 주세요.':'';
    colorStyles($('#theme-preview'),draft.colors);$('#theme-preview').style.colorScheme=darkColor(draft.colors.paper)?'dark':'light';
  }
  function cancel(){if(busy)return;$('#theme-dialog').hidden=true;draft=null;}
  $$('[data-theme-choice]').forEach(b=>b.onclick=run(()=>call('preferences',{theme:b.dataset.themeChoice})));
  $('#theme-new').onclick=()=>begin();$('#theme-import').onclick=run(()=>call('importTheme'));
  $('#theme-editor-close').onclick=$('#theme-cancel').onclick=cancel;
  $('#theme-name').addEventListener('input',preview);
  $$('[data-theme-base]').forEach(b=>b.onclick=()=>{if(!draft||busy)return;draft.colors={...palettes[b.dataset.themeBase]};renderFields();});
  $('#theme-save').onclick=run(async()=>{
    if(!draft||busy||$('#theme-save').disabled)return;
    busy=true;preview();const saved={name:draft.name,colors:{...draft.colors},...(draft.id?{themeID:draft.id}:{})};
    try{await call('saveTheme',saved);$('#theme-dialog').hidden=true;draft=null;toast(saved.name+' 테마를 적용했어요.');}
    finally{busy=false;preview();}
  });
  return {sync,cancel};
}
