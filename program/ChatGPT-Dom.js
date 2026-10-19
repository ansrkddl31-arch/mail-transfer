// Service adapters are deliberately isolated. No arbitrary JavaScript from AI output is executed.
function exChatDom(action, expected, provider='chatgpt', model='') {
 const config={
  chatgpt:{host:'chatgpt.com',composer:'#prompt-textarea',user:'[data-message-author-role="user"]',assistant:'[data-message-author-role="assistant"]',send:'button[data-testid="send-button"],button#composer-submit-button,button[aria-label="Send prompt"],button[aria-label="프롬프트 보내기"]',stop:'button[data-testid="stop-button"],button[aria-label="Stop generating"],button[aria-label="생성 중지"],button[aria-label="Stop streaming"]',picker:'[data-testid="model-switcher-dropdown-button"]'},
  claude:{host:'claude.ai',composer:'[contenteditable="true"][data-testid="chat-input"],.ProseMirror[contenteditable="true"],[contenteditable="true"][role="textbox"]',user:'[data-testid="user-message"]',assistant:'[data-is-streaming],.font-claude-response,[data-testid="assistant-message"]',send:'button[aria-label="Send message"],button[aria-label="메시지 보내기"],button[data-testid="send-button"]',stop:'button[aria-label="Stop response"],button[aria-label="응답 중지"],button[aria-label="Stop generating"]',picker:'[data-testid="model-selector-dropdown"],button[aria-label="Select model"],button[aria-label="모델 선택"]'},
  gemini:{host:'gemini.google.com',composer:'rich-textarea [contenteditable="true"],.ql-editor[contenteditable="true"]',user:'user-query',assistant:'model-response',send:'button.send-button,button[aria-label="Send message"],button[aria-label="메시지 보내기"]',stop:'button[aria-label="Stop response"],button[aria-label="응답 중지"],button.stop-button',picker:'button[data-test-id="bard-mode-menu-button"],button[aria-label="Open mode picker"],button[aria-label="모드 선택 도구 열기"]'}
 }[provider];
 const result=(code,extra={})=>({code,...extra});
 if(!config||location.protocol!=='https:'||location.hostname!==config.host)return result('CHAT_LOGIN_REQUIRED');
 const visible=e=>!!e&&!e.disabled&&e.getBoundingClientRect().width>0&&e.getBoundingClientRect().height>0&&getComputedStyle(e).visibility!=='hidden';
 const text=e=>(e?.innerText||e?.textContent||'').trim();
 const main=document.querySelector('main')||document.body;
 const alerts=Array.from(document.querySelectorAll('[role="alert"],[data-testid="conversation-turn-error"]')).filter(visible).map(text).join('\n');
 if(/you.ve reached|usage limit|message limit|too many requests|사용량.*제한|한도에 도달|메시지.*한도/i.test(alerts))return result('CHAT_USAGE_LIMIT');
 if(/verify you are human|checking your browser|사람인지 확인|보안 확인/i.test((document.title||'')+' '+(document.body.innerText||'').slice(0,3000))||document.querySelector('iframe[src*="challenges.cloudflare.com"]'))return result('CHAT_CHALLENGE_REQUIRED');
 if(alerts.trim())return result('CHAT_SERVICE_ERROR');
 if(Array.from(document.querySelectorAll('a,button')).some(e=>visible(e)&&/^(log in|sign in|로그인)$/i.test(text(e))))return result('CHAT_LOGIN_REQUIRED');
 const composers=Array.from(document.querySelectorAll(config.composer)).filter(visible);const composer=composers.length===1?composers[0]:null;
 const picker=document.querySelector(config.picker);
 const current=picker?text(picker).slice(0,100):'';
 if(action==='ready')return result(composer?'READY':'WAIT',{current});
 if(action==='models'){
  const menus=Array.from(document.querySelectorAll('[role="menu"],[role="listbox"]')).filter(visible);
  if(!menus.length){if(picker&&visible(picker)){picker.click();return result('MODEL_MENU_OPENING',{current})}return result('MODELS',{models:[],current});}
  const options=menus.flatMap(e=>Array.from(e.querySelectorAll('[role="menuitem"],[role="menuitemradio"],[role="option"]'))).filter(visible);
  const models=[...new Set(options.map(text).filter(t=>t.length>0&&t.length<=100))].slice(0,30);
  return result('MODELS',{models,current});
 }
 if(action==='select-model'){
  if(!model)return result('MODEL_SELECTED');
  if(current===model)return result('MODEL_SELECTED');
  const menus=Array.from(document.querySelectorAll('[role="menu"],[role="listbox"]')).filter(visible);
  const options=menus.flatMap(e=>Array.from(e.querySelectorAll('[role="menuitem"],[role="menuitemradio"],[role="option"]'))).filter(e=>visible(e)&&text(e)===model);
  if(options.length===1){options[0].click();return result('MODEL_CLICKED');}
  if(!menus.length&&picker&&visible(picker)){picker.click();return result('MODEL_MENU_OPENING');}
  return result('CHAT_MODEL_UNAVAILABLE');
 }
 if(action==='dismiss-models'){if(picker&&document.querySelector('[role="menu"],[role="listbox"]'))picker.click();return result('OK');}
 if(action==='focus'){
  if(!composer)return result('CHAT_LAYOUT_UNSUPPORTED');
  if((composer.value||text(composer)).trim())return result('CHAT_COMPOSER_NOT_EMPTY');
  if(document.querySelector(config.user))return result('CHAT_CONVERSATION_NOT_EMPTY');
  composer.focus();return result(document.activeElement===composer?'FOCUSED':'CHAT_LAYOUT_UNSUPPORTED');
 }
 if(action==='prepare-files'){
  if(document.querySelector('input[type="file"]'))return result('FILE_INPUT_READY');
  const upload=Array.from(document.querySelectorAll('[role="menuitem"],button')).filter(e=>visible(e)&&/^(upload files?|upload from computer|add files?|파일 업로드|파일 추가|컴퓨터에서 업로드|사진 및 파일 추가)$/i.test(text(e)));
  if(upload.length===1){upload[0].click();return result('UPLOAD_OPENING');}
  const selector={chatgpt:'button[data-testid="composer-plus-btn"]',claude:'button[aria-label="Add content"],button[aria-label="Upload files"],button[aria-label="콘텐츠 추가"]',gemini:'button[aria-label="Add files"],button[aria-label="파일 추가"],button[aria-label="Open upload file menu"],button[aria-label="파일 업로드 메뉴 열기"]'}[provider];
  const plus=Array.from(document.querySelectorAll(selector)).filter(visible);if(plus.length===1){plus[0].click();return result('UPLOAD_OPENING');}
  return result('CHAT_ATTACHMENT_UNSUPPORTED');
 }
 if(action==='files'){
  const names=JSON.parse(expected||'[]');
  const scope=composer?.closest('form')||composer?.parentElement?.parentElement||main;
  const pageText=text(scope)+'\n'+text(main);
  const pending=Array.from(scope.querySelectorAll('[role="progressbar"],[aria-busy="true"],[data-upload-status="uploading"]')).some(visible);
  const errors=Array.from(scope.querySelectorAll('[role="alert"],.error')).filter(visible).map(text).join(' ');
  if(errors)return result('CHAT_ATTACHMENT_FAILED');
  return result(!pending&&names.length&&names.every(n=>pageText.includes(n))?'FILES_READY':'FILES_WAIT');
 }
 const submitted=Array.from(main.querySelectorAll(config.user)).some(e=>text(e)===String(expected||'').trim());
 if(action==='submit'){
  if(submitted)return result('ALREADY_SUBMITTED');
  if(!composer||(composer.value||text(composer)).trim()!==String(expected||'').trim())return result('CHAT_INPUT_MISMATCH');
  const unique=[...new Set(Array.from(document.querySelectorAll(config.send)).filter(visible))];if(unique.length!==1)return result('CHAT_LAYOUT_UNSUPPORTED');
  unique[0].click();return result('CLICKED');
 }
 if(!submitted&&!['artifacts','download'].includes(action))return result('WAIT_SUBMISSION');
 const assistant=Array.from(main.querySelectorAll(config.assistant)).filter(e=>!e.parentElement?.closest(config.assistant)).pop();
 if(!assistant)return result('WAIT_ANSWER');
 const artifactLinks=Array.from(assistant.querySelectorAll('a[href]')).filter(a=>{
  const href=a.getAttribute('href')||'';let url;try{url=new URL(href,location.href)}catch{return false}
  const same=url.protocol==='https:'&&url.hostname===config.host;
  const blob=url.protocol==='blob:'&&url.origin===location.origin;
  return (/^sandbox:\/mnt\/data\//.test(href)||(same||blob)&&(a.hasAttribute('download')||/\/backend-api\/files\/|\/api\/.*(?:download|file)|\/artifacts\/.*download/.test(url.pathname)));
 });
 if(action==='artifacts')return result('ARTIFACTS',{count:Math.min(artifactLinks.length,3),names:artifactLinks.slice(0,3).map(a=>a.getAttribute('download')||text(a))});
 if(action==='download'){
  const index=Number(expected);if(!Number.isInteger(index)||index<0||index>=Math.min(artifactLinks.length,3))return result('CHAT_DOWNLOAD_UNSUPPORTED');
  artifactLinks[index].click();return result('DOWNLOAD_CLICKED');
 }
 const answer=text(assistant.querySelector('.markdown,.markdown-main-panel')||assistant);
 const stop=Array.from(document.querySelectorAll(config.stop)).some(visible)||assistant.getAttribute('data-is-streaming')==='true';
 const turn=assistant.closest('article,[data-testid^="conversation-turn-"],.response-container')||assistant.parentElement;
 const completed=!!turn&&Array.from(turn.querySelectorAll('button')).some(e=>visible(e)&&/copy|good response|bad response|복사|좋은 응답|별로인 응답|thumb_up|thumb_down/i.test((e.getAttribute('aria-label')||'')+' '+(e.getAttribute('data-testid')||'')));
 return result('ANSWER',{text:answer,streaming:stop,completed,model:current});
}
