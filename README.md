# NextDNS ONJN Import (PowerShell)

Import automat al domeniilor din “Lista neagra” ONJN in NextDNS (Denylist), fara Python si fara instalari suplimentare (ruleaza cu Windows PowerShell 5.1).

> ⚠️ Notă: acest proiect este un utilitar neoficial. Lista ONJN este o sursa publica pentru domenii nelicentiate / restrictionate, dar NextDNS ramane sursa de adevar pentru ce se blocheaza efectiv in reteaua ta.

## Ce face scriptul

- Descarca lista ONJN (Lista-neagra.txt)
- Normalizeaza domeniile (lowercase, trim, elimina comentarii, elimina `*.`)
- Deduplica lista
- Citeste denylist-ul existent din profilul NextDNS
- Face merge (pastreaza intrarile existente + adauga domeniile ONJN cu `active=true`)
- Face backup la denylist-ul curent
- Update in bulk prin NextDNS API (PUT) ca sa evite rate-limit (429)

## Cerinte

- Windows PowerShell 5.1 (cel clasic din Windows)
- Cont NextDNS + un profil (configuration)
- NextDNS API Key
- Acces la Internet

## Cum obtii NextDNS API Key

1. Autentifica-te in NextDNS: https://my.nextdns.io
2. Mergi la pagina Account: https://my.nextdns.io/account
3. Deruleaza pana jos – vei vedea “API key” (copiezi cheia)

Documentatie oficiala NextDNS API: https://nextdns.github.io/api/ (API key se foloseste in header-ul `X-Api-Key`). 

> Important: nu comite API key-ul in GitHub.

## Cum gasesti Profile ID

Ruleaza scriptul o data manual:
- iti listeaza profilele disponibile (id + name)
- alegi id-ul dorit (ex: `36565d`)

## Rulare manuala (one-shot)

1) Descarca scriptul local (sau cloneaza repo-ul).

2) (Optional) Deblocheaza fisierul daca a fost descarcat din Internet:
```powershell
Unblock-File .\nextcloud.ps1

## Ruleaza cu bypass doar pentru sesiunea curenta:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\nextcloud.ps1
