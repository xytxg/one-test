const enc=new TextEncoder();
export const b64url=b=>btoa(String.fromCharCode(...b)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
export const unb64url=s=>Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')+'==='.slice((s.length+3)%4)),c=>c.charCodeAt(0));
export async function sha256(t){const d=await crypto.subtle.digest('SHA-256',enc.encode(t));return[...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,'0')).join('')}
export function randomToken(n=32){const b=new Uint8Array(n);crypto.getRandomValues(b);return b64url(b)}
export async function derivePassword(p,s,i=210000){const k=await crypto.subtle.importKey('raw',enc.encode(p),'PBKDF2',false,['deriveBits']);const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:unb64url(s),iterations:i},k,256);return b64url(new Uint8Array(bits))}
export function timingSafeEqual(a,b){if(typeof a!=='string'||typeof b!=='string'||a.length!==b.length)return false;let r=0;for(let i=0;i<a.length;i++)r|=a.charCodeAt(i)^b.charCodeAt(i);return r===0}
