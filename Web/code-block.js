import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight';
import {common, createLowlight} from 'lowlight';

const lowlight = createLowlight(common);
const names = {
  javascript:'JavaScript', typescript:'TypeScript', python:'Python', swift:'Swift',
  json:'JSON', xml:'HTML / XML', css:'CSS', scss:'SCSS', bash:'Bash', shell:'Shell',
  sql:'SQL', yaml:'YAML', markdown:'Markdown', java:'Java', kotlin:'Kotlin',
  go:'Go', rust:'Rust', c:'C', cpp:'C++', csharp:'C#', objectivec:'Objective-C',
  php:'PHP', ruby:'Ruby', graphql:'GraphQL', plaintext:'일반 텍스트'
};
const languages = lowlight.listLanguages().filter(name=>name!=='plaintext')
  .sort((a,b)=>(names[a]||a).localeCompare(names[b]||b));

export const HighlightedCodeBlock = CodeBlockLowlight.extend({
  addNodeView() {
    return ({node, editor, getPos}) => {
      let current = node;
      const dom = document.createElement('div');
      dom.className = 'code-block';
      const toolbar = document.createElement('div');
      toolbar.className = 'code-block-toolbar';
      toolbar.contentEditable = 'false';
      const label = document.createElement('label');
      label.append(document.createTextNode('코드 언어'));
      const select = document.createElement('select');
      select.className = 'code-language';
      select.setAttribute('aria-label','코드 언어');
      select.append(new Option('자동 감지',''),new Option('일반 텍스트','plaintext'));
      for (const language of languages) select.append(new Option(names[language]||language,language));
      label.append(select);
      toolbar.append(label);
      const pre = document.createElement('pre');
      const contentDOM = document.createElement('code');
      pre.append(contentDOM);
      dom.append(toolbar,pre);

      function sync() {
        const language = current.attrs.language || '';
        // Preserve imported aliases and unsupported fence labels on export.
        for (const option of select.querySelectorAll('[data-imported]')) option.remove();
        if (language && !Array.from(select.options).some(option=>option.value===language)) {
          const option = new Option(language+(lowlight.registered(language)?'':' · 자동 감지'),language);
          option.dataset.imported = 'true';
          select.append(option);
        }
        select.value = language;
        select.disabled = !editor.isEditable;
        const className = language ? 'language-'+language : '';
        if (contentDOM.className !== className) contentDOM.className = className;
      }
      select.addEventListener('change',()=>{
        if (!editor.isEditable) return;
        const position = getPos();
        if (typeof position !== 'number') return;
        editor.commands.command(({tr})=>{
          tr.setNodeMarkup(position,undefined,{...current.attrs,language:select.value||null});
          return true;
        });
      });
      sync();
      return {
        dom, contentDOM,
        update(updated) {
          if (updated.type !== current.type) return false;
          current = updated;
          sync();
          return true;
        },
        stopEvent: event=>toolbar.contains(event.target),
        ignoreMutation: mutation=>mutation.type!=='selection' &&
          (mutation.type==='attributes' && mutation.target===contentDOM || !contentDOM.contains(mutation.target))
      };
    };
  }
}).configure({lowlight,defaultLanguage:null});
