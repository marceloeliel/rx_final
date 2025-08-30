#!/bin/bash

# 🚀 Deploy RX Veículos - rxnegocio.com.br
# Script personalizado para deploy na VPS

set -e  # Para em caso de erro

echo "🚀 Iniciando deploy na VPS..."

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para log colorido
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configurações
APP_NAME="rx-veiculos"
APP_DIR="/opt/rx-veiculos"
REPO_URL="https://github.com/marceloeliel/rx-git.git"
NODE_VERSION="20"
PORT="3000"
DOMAIN="rxnegocio.com.br"

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    log_error "Este script deve ser executado como root"
    exit 1
fi

log_info "Atualizando sistema..."
apt update && apt upgrade -y

log_info "Instalando dependências do sistema..."
apt install -y curl wget git nginx certbot python3-certbot-nginx ufw

# Instalar Node.js via NodeSource
log_info "Instalando Node.js ${NODE_VERSION}..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt install -y nodejs

# Instalar pnpm e pm2
log_info "Instalando pnpm e pm2..."
npm install -g pnpm pm2

# Criar usuário para a aplicação
log_info "Criando usuário da aplicação..."
if ! id "rxapp" &>/dev/null; then
    useradd -r -s /bin/bash -d /opt/rx-veiculos rxapp
fi

# Criar diretório da aplicação
log_info "Preparando diretório da aplicação..."
mkdir -p $APP_DIR
chown rxapp:rxapp $APP_DIR

# Remover projeto antigo se existir
if [ -d "$APP_DIR/.git" ]; then
    log_info "Removendo projeto antigo..."
    rm -rf $APP_DIR/*
    rm -rf $APP_DIR/.*
fi

# Clonar repositório
log_info "Clonando repositório..."
cd $APP_DIR
sudo -u rxapp git clone $REPO_URL .

# Instalar dependências
log_info "Instalando dependências do projeto..."
sudo -u rxapp pnpm install

# Criar arquivo de variáveis de ambiente
log_info "Criando arquivo de variáveis de ambiente..."
cat > $APP_DIR/.env.local << 'EOF'
# Configurações de Produção
NODE_ENV=production
PORT=3000
HOSTNAME=0.0.0.0

# URLs da aplicação
NEXTAUTH_URL=https://rxnegocio.com.br
NEXT_PUBLIC_APP_URL=https://rxnegocio.com.br
WEBSITE_URL=https://rxnegocio.com.br

# NextAuth Secret
NEXTAUTH_SECRET=rx_veiculos_secret_2024_production_key

# Supabase (configurar depois)
NEXT_PUBLIC_SUPABASE_URL=https://sua-url.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=sua_chave_anonima
SUPABASE_SERVICE_ROLE_KEY=sua_service_role_key
DATABASE_URL=postgresql://usuario:senha@host:porta/database

# FIPE API
NEXT_PUBLIC_FIPE_API_TOKEN=seu_token_fipe
EOF

chown rxapp:rxapp $APP_DIR/.env.local
chmod 600 $APP_DIR/.env.local

# Build da aplicação
log_info "Fazendo build da aplicação..."
sudo -u rxapp pnpm build

# Configurar PM2
log_info "Configurando PM2..."
cat > $APP_DIR/ecosystem.config.js << 'EOF'
module.exports = {
  apps: [{
    name: 'rx-veiculos',
    script: 'pnpm',
    args: 'start',
    cwd: '/opt/rx-veiculos',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      PORT: 3000
    }
  }]
};
EOF

chown rxapp:rxapp $APP_DIR/ecosystem.config.js

# Configurar Nginx
log_info "Configurando Nginx..."
cat > /etc/nginx/sites-available/rx-veiculos << EOF
server {
    listen 80;
    server_name rxnegocio.com.br www.rxnegocio.com.br;
    
    # Redirecionar HTTP para HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name rxnegocio.com.br www.rxnegocio.com.br;
    
    # Certificados SSL (serão configurados pelo Certbot)
    ssl_certificate /etc/letsencrypt/live/rxnegocio.com.br/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/rxnegocio.com.br/privkey.pem;
    
    # Configurações SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    
    # Headers de segurança
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    # Proxy para Next.js
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # Cache para assets estáticos
    location /_next/static/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_cache_valid 200 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # Logs
    access_log /var/log/nginx/rx-veiculos.access.log;
    error_log /var/log/nginx/rx-veiculos.error.log;
}
EOF

# Ativar site no Nginx
ln -sf /etc/nginx/sites-available/rx-veiculos /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Testar configuração do Nginx
nginx -t

# Configurar firewall
log_info "Configurando firewall..."
ufw --force enable
ufw allow ssh
ufw allow 'Nginx Full'

# Iniciar PM2 como usuário rxapp
log_info "Iniciando aplicação com PM2..."
sudo -u rxapp pm2 start $APP_DIR/ecosystem.config.js
sudo -u rxapp pm2 save
sudo -u rxapp pm2 startup

# Reiniciar Nginx
log_info "Reiniciando Nginx..."
systemctl restart nginx

log_success "✅ Deploy concluído!"

echo ""
echo "📋 PRÓXIMOS PASSOS:"
echo ""
echo "1. 🌐 Configure o DNS do domínio rxnegocio.com.br apontando para este servidor"
echo ""
echo "2. 🔒 Configure SSL com Let's Encrypt:"
echo "   certbot --nginx -d rxnegocio.com.br -d www.rxnegocio.com.br"
echo ""
echo "3. 📝 Edite as variáveis de ambiente se necessário:"
echo "   nano $APP_DIR/.env.local"
echo ""
echo "4. 📊 Verifique o status da aplicação:"
echo "   sudo -u rxapp pm2 status"
echo "   sudo -u rxapp pm2 logs rx-veiculos"
echo ""
echo "5. 🔄 Para atualizar a aplicação:"
echo "   cd $APP_DIR && git pull && pnpm install && pnpm build && sudo -u rxapp pm2 restart rx-veiculos"
echo ""
log_success "🎉 Aplicação pronta para uso em https://rxnegocio.com.br!"