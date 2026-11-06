"use strict";
/**
 * Streaming Reflection Beam issue authoring. BYOK session key is never logged or
 * stored. A server REFLECTION_API_KEY can be used only by a GitHub-authenticated
 * owner, so this public dashboard cannot spend arbitrary server credits.
 */
const MODEL="Beam-1.0-501B-A23B";
const API="https://api.reflection.ai/openai/v1/chat/completions";
function json(res,s,obj){res.statusCode=s;res.setHeader("Content-Type","application/json; charset=utf-8");res.setHeader("Cache-Control","no-store");res.end(JSON.stringify(obj))}
function clean(x,max){return String(x??"").trim().slice(0,max)}
async function verifiedOwner(token){
 if(!token)return false;
 try{const r=await fetch("https://api.github.com/user",{headers:{Authorization:"Bearer "+token,Accept:"application/vnd.github+json"},signal:AbortSignal.timeout(9000)});if(!r.ok)return false;const u=await r.json();return u.login==="duggal1"}catch{return false}
}
export default async function handler(req,res){
 if(req.method!=="POST")return json(res,405,{error:"POST required"});
 const length=Number(req.headers["content-length"]||0);if(length>16000)return json(res,413,{error:"Request too large"});
 const provided=clean(req.headers["x-reflection-key"],320);
 const githubToken=clean(req.headers["x-github-token"],320);
 let key=provided;
 if(!key && process.env.REFLECTION_API_KEY){
   // No anonymous public proxy that spends a deployer's AI budget.
   if(!await verifiedOwner(githubToken))return json(res,401,{error:"Connect as repository owner for server-backed AI or provide your own Reflection key for this session."});
   key=process.env.REFLECTION_API_KEY;
 }
 if(!key)return json(res,422,{error:"Reflection API key is not configured. Enter it in this session, or set REFLECTION_API_KEY on Vercel."});
 let data=req.body;
 if(typeof data==="string"){try{data=JSON.parse(data)}catch{return json(res,400,{error:"Invalid JSON"})}}
 if(!data||typeof data!=="object")return json(res,400,{error:"JSON request required"});
 const fields={
  title:clean(data.title,180), symptoms:clean(data.symptoms,1900), reproduction:clean(data.reproduction,2400),
  expected:clean(data.expected,1200), observed:clean(data.observed,1200), modules:clean(data.modules,1500),
  priority:clean(data.priority,20), evidence:clean(data.evidence,2200)
 };
 if(fields.title.length<6||(!fields.symptoms&&!fields.observed))return json(res,422,{error:"Enter an issue title and observed failure before generating a draft."});
 const system=[
 "You write high-precision issue reports for a Swift 6 and Metal macOS screen recording application named Lumen.",
 "Write a practical and concise GitHub issue body in Markdown. Do not write a title; the user edits it separately.",
 "Use ONLY the supplied observation and context. Never invent reproduction steps, source paths, stack traces, test results, performance metrics, cause certainty, PRs, or checks.",
 "Clearly distinguish Observed, Reproduction (if available), Expected, Suspected root cause (if actually provided), Affected files (if supported), Acceptance criteria, Tests required, and Unknowns.",
 "If facts are missing, mark 'Not established' or 'To verify' rather than filling gaps.",
 "Do not claim an issue is fixed/merged or CI green unless specific evidence says so.",
 "A good issue tells the coding agent how to reproduce and prove a fix, not just what to change.",
 "Output only GitHub-flavored Markdown body. No fences, no preamble, no fabricated specifics."
 ].join(" ");
 const ctrl=new AbortController();const timeout=setTimeout(()=>ctrl.abort(),85000);
 try{
   const response=await fetch(API,{method:"POST",headers:{Authorization:"Bearer "+key,"Content-Type":"application/json"},
     body:JSON.stringify({model:MODEL,stream:true,temperature:0.4,top_p:0.99,reasoning_effort:"medium",
       max_completion_tokens:2600,messages:[{role:"system",content:system},{role:"user",content:JSON.stringify(fields)}]}),signal:ctrl.signal});
   if(!response.ok){
     let msg=await response.text().catch(()=>"");
     try{const j=JSON.parse(msg);msg=j.error?.message||j.message||msg}catch{}
     return json(res,response.status===401?401:502,{error:("Reflection API: "+clean(msg,420))||"Model request failed"});
   }
   res.statusCode=200;res.setHeader("Content-Type","text/event-stream; charset=utf-8");
   res.setHeader("Cache-Control","no-cache, no-transform");res.setHeader("X-Content-Type-Options","nosniff");
   res.setHeader("X-Accel-Buffering","no");res.flushHeaders?.();
   const reader=response.body?.getReader();if(!reader){res.write("event: error\ndata: "+JSON.stringify({error:"No stream returned"})+"\n\n");return res.end()}
   const decoder=new TextDecoder();let buffer="",emitted=0,done=false;
   while(!done){
     const {value,done:streamDone}=await reader.read();if(streamDone)break;buffer+=decoder.decode(value,{stream:true});
     const lines=buffer.split("\n");buffer=lines.pop()||"";
     for(const raw of lines){
       const line=raw.trim();if(!line.startsWith("data:"))continue;
       const rawData=line.slice(5).trim();if(rawData==="[DONE]"){done=true;break}
       try{
         const part=JSON.parse(rawData);
         if(part.error){res.write("event: error\ndata: "+JSON.stringify({error:clean(part.error.message||"Model streaming error",360)})+"\n\n");done=true;break}
         const content=part.choices?.[0]?.delta?.content;
         if(typeof content==="string"&&content){
           emitted+=content.length;
           if(emitted>15000){done=true;break}
           // Deliberately do not forward model reasoning_content to the browser.
           res.write("event: token\ndata: "+JSON.stringify({content})+"\n\n");
         }
       }catch{}
     }
   }
   res.write("event: done\ndata: "+JSON.stringify({model:MODEL,characters:emitted})+"\n\n");
   res.end();
 }catch(e){
   if(!res.headersSent)json(res,502,{error:e.name==="AbortError"?"Reflection request timed out":"Reflection request could not be completed"});
   else{res.write("event: error\ndata: "+JSON.stringify({error:e.name==="AbortError"?"Model request timed out":"Connection to Reflection was interrupted"})+"\n\n");res.end()}
 }finally{clearTimeout(timeout)}
};