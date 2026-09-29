# hedefteknoloji-yayin

hedefteknolojibilisim.com'un **otomatik üretilen** yayın deposu — elle düzenlemeyin.

- `public/` — derlenmiş statik site
- `_ops/` — sunucu betiği (`deploy.sh`), canlı test listesi, yayın kimliği, `SHA256SUMS` ve imzası

Dallar: `main` = canlı, `staging` = test ortamı. Sunucu yalnız imzası doğrulanan sürümleri kurar;
imza anahtarı bu depoda yoktur. Kaynak kodu ayrı (özel) depodadır.
