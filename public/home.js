import {mountAccount} from '/shared/account.js';
mountAccount(document.querySelector('#account'));

const about=document.getElementById('home-about-dialog');
document.getElementById('home-about').onclick=()=>about.showModal();
document.getElementById('home-about-close').onclick=()=>about.close();
