importScripts("https://www.gstatic.com/firebasejs/10.13.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.13.2/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyBTBjqut1fGy5Ob3J4nxrG9sFS0NQj8Bg0",
  authDomain: "try-auth-f5762.firebaseapp.com",
  projectId: "try-auth-f5762",
  storageBucket: "try-auth-f5762.firebasestorage.app",
  messagingSenderId: "471745302305",
  appId: "1:471745302305:web:daf3fc000f32ff49117860"
});

const messaging = firebase.messaging();
