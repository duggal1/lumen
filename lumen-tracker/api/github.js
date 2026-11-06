"use strict";
/**
 * The browser supplies a fine-grained GitHub PAT for each write; the server
 * forwards it only to api.github.com and never stores or logs it.
 * This app does not inherit the deployer's Vercel/GitHub integration token.
 */
const ORG="duggal1", REPO="lumen";
const GH="https://api.github.com";
function reply(res,status,body){res.statusCode=status;res.setHeader("Content-Type","application/json; charset=utf-8");res.setHeader("Cache-Control","no-store");res.setHeader("X-Content-Type-Options","nosniff");res.end(JSON.stringify(body))}
function tokenFrom(req){const s=String(req.headers.authorization||"");return /^Bearer [A-Za-z0-9_]+$/.test(s)?s.slice(7):null}
function ghHeaders(token){return {"Accept":"application/vnd.github+json","X-GitHub-Api-Version":"2022-11-28",...(token?{"Authorization":"Bearer "+token}:{})}}
async function fromGithub(path,token,opts={}){
  const r=await fetch(GH+path,{...opts,headers:{...ghHeaders(token),...(opts.headers||{})},signal:AbortSignal.timeout(18000)});
  const json=await r.json().catch(()=>({message:"Unreadable GitHub response"}));
  if(!r.ok){const message=typeof json.message==="string"?json.message:"GitHub API error";const e=new Error(message);e.status=r.status;throw e}
  return json;
}
export default async function handler(req,res){
  if(req.method!=="GET"&&req.method!=="POST")return reply(res,405,{error:"Use GET or POST"});
  const auth=tokenFrom(req);
  try{
    if(req.method==="GET"){
      if(req.query?.resource!=="issues")return reply(res,400,{error:"Unsupported read resource"});
      // Public read. PRs are excluded by GitHub's pull_request field.
      const items=await fromGithub("/repos/"+ORG+"/"+REPO+"/issues?state=all&per_page=100&sort=updated",auth);
      return reply(res,200,{repository:ORG+"/"+REPO,source:"GitHub REST API",
        issues:items.filter(x=>!x.pull_request).map(x=>({number:x.number,title:x.title,body:x.body||"",state:x.state,state_reason:x.state_reason||null,
          html_url:x.html_url,created_at:x.created_at,updated_at:x.updated_at,closed_at:x.closed_at,comments:x.comments,
          user:x.user?.login,labels:(x.labels||[]).map(v=>v.name)}))});
    }
    if(!auth)return reply(res,401,{error:"Connect a fine-grained GitHub token with Issues: read/write access to duggal1/lumen"});
    const length=Number(req.headers["content-length"]||0);
    if(length>26000)return reply(res,413,{error:"Request exceeds 26 KB"});
    let body=req.body;
    if(typeof body==="string"){try{body=JSON.parse(body)}catch{return reply(res,400,{error:"Invalid JSON"})}}
    if(!body||typeof body!=="object")return reply(res,400,{error:"JSON body required"});
    if(body.action==="verify"){
      const user=await fromGithub("/user",auth);
      return reply(res,200,{login:user.login,avatar_url:user.avatar_url,publicUrl:user.html_url,
        note:"Identity verified. GitHub enforces repository Issues: write permission when publishing."});
    }
    if(body.action!=="create")return reply(res,400,{error:"Unsupported action"});
    const title=String(body.title||"").trim(),issueBody=String(body.body||"").trim();
    if(title.length<6||title.length>180)return reply(res,422,{error:"Title must contain 6 to 180 characters"});
    if(!issueBody||issueBody.length>16000)return reply(res,422,{error:"Issue body must contain 1 to 16,000 characters"});
    const created=await fromGithub("/repos/"+ORG+"/"+REPO+"/issues",auth,{
      method:"POST",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({title,body:issueBody})
    });
    return reply(res,201,{success:true,number:created.number,html_url:created.html_url,state:created.state,
      title:created.title,created_at:created.created_at,user:created.user?.login});
  }catch(e){
    const status=Number(e.status)||502;
    const safe=status===401?"Token is invalid or expired. Reconnect GitHub.":status===403?
      "GitHub rejected the request. Check repository Issues write permission, token scope, and rate limits.":
      status===404?"Repository not found or not accessible with this token.":
      status===422?"GitHub rejected the issue fields. Check for duplicates or validation errors.":
      status===502?"Unable to reach GitHub right now.":String(e.message||"GitHub request failed");
    return reply(res,status>=400&&status<600?status:502,{error:safe});
  }
};