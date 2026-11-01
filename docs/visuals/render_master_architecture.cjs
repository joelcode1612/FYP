const fs = require('fs');
const path = require('path');
const {pathToFileURL} = require('url');
const {chromium} = require('../../fyp_jaspr_web/tool/node_modules/playwright-core');
(async()=>{
  const cache=path.join(process.env.USERPROFILE,'AppData','Local','ms-playwright');
  const dirs=fs.readdirSync(cache).filter(x=>/^chromium-\d+$/.test(x)).sort((a,b)=>+b.split('-')[1]-+a.split('-')[1]);
  const executablePath=path.join(cache,dirs[0],'chrome-win64/chrome.exe');
  const browser=await chromium.launch({executablePath});
  try{
    const page=await browser.newPage({viewport:{width:3600,height:1200},deviceScaleFactor:1});
    await page.goto(pathToFileURL(path.join(__dirname,'sitewise-master-architecture.svg')).href);
    const bounds=await page.locator('text').evaluateAll(nodes=>nodes.map(n=>{const b=n.getBBox();return {text:n.textContent,x:b.x,y:b.y,right:b.x+b.width,bottom:b.y+b.height}}));
    const overflow=bounds.filter(b=>b.x<0||b.right>3600||b.bottom>11106);
    if(overflow.length)throw new Error('Text outside canvas: '+JSON.stringify(overflow));
    await page.setViewportSize({width:2400,height:1000});
    await page.goto('about:blank');
    await page.setContent('<html><head><style>body{margin:0}svg{display:block;width:2400px;height:auto}</style></head><body>'+fs.readFileSync(path.join(__dirname,'sitewise-master-architecture.svg'),'utf8')+'</body></html>');
    await page.screenshot({path:path.join(__dirname,'sitewise-master-architecture.png'),fullPage:true,timeout:120000});
    await page.setViewportSize({width:2400,height:2000});
    await page.screenshot({path:path.join(__dirname,'sitewise-master-detail.png'),clip:{x:190,y:1086,width:1040,height:500},timeout:120000});
    const view=await browser.newPage({viewport:{width:1600,height:1000}});
    await view.goto(pathToFileURL(path.join(__dirname,'sitewise-master-architecture.html')).href);
    if(await view.locator('[data-track]').count()!==34)throw new Error('Missing tracks');
    await view.locator('[data-track="A04"]').click();
    if(!await view.locator('#note').isVisible())throw new Error('Missing workflow note');
    await view.locator('#plus').click();
    await view.screenshot({path:path.join(__dirname,'sitewise-master-viewer.png')});
    console.log('Rendered full-size PNG; checked 34 track links, zoom controls, notes, and canvas bounds.');
  }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
