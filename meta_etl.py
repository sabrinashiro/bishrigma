# meta_etl.py
# ============================================================
# Meta Ads API → Supabase ETL
# Métricas: CVR, CPA, ROAS, hook rate, hold rate, cost_per_hook,
#           outbound_ctr (direto Meta), frequência nível conta,
#           anúncios campeões do mês (ROAS > 5.5 + spend > R$1.000)
# ============================================================

import os
import time
import logging
from datetime import datetime, timedelta

from facebook_business.api import FacebookAdsApi
from facebook_business.adobjects.adaccount import AdAccount
from facebook_business.adobjects.adsinsights import AdsInsights
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────

META_TOKEN    = os.environ["META_ACCESS_TOKEN"]
AD_ACCOUNT_ID = os.environ["META_AD_ACCOUNT_ID"]   # ex: "act_123456789"
SUPABASE_URL  = os.environ["SUPABASE_URL"]
SUPABASE_KEY  = os.environ["SUPABASE_SERVICE_KEY"]  # service_role key

FacebookAdsApi.init(access_token=META_TOKEN)
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)


# ─────────────────────────────────────────────────────────────
# Campos da API — nível AD
# ─────────────────────────────────────────────────────────────

FIELDS_AD = [
    AdsInsights.Field.ad_id,
    AdsInsights.Field.ad_name,
    AdsInsights.Field.adset_id,
    AdsInsights.Field.adset_name,
    AdsInsights.Field.campaign_id,
    AdsInsights.Field.campaign_name,
    AdsInsights.Field.account_id,
    AdsInsights.Field.date_start,
    AdsInsights.Field.date_stop,
    AdsInsights.Field.impressions,
    AdsInsights.Field.spend,
    AdsInsights.Field.clicks,
    AdsInsights.Field.actions,                          # compras
    AdsInsights.Field.action_values,                    # receita
    AdsInsights.Field.video_thruplay_watched_actions,   # hook rate
    AdsInsights.Field.video_30_sec_watched_actions,     # hold rate (30s)
    AdsInsights.Field.outbound_clicks_ctr,              # CTR outbound (Meta calcula)
    AdsInsights.Field.created_time,                     # data de criação do anúncio
]

PARAMS_AD = {
    "level": "ad",
    "time_increment": 1,            # 1 linha por dia por anúncio
    "action_breakdowns": ["action_type"],
}


# ─────────────────────────────────────────────────────────────
# Campos da API — nível ACCOUNT (frequência)
# ─────────────────────────────────────────────────────────────

FIELDS_ACCOUNT = [
    AdsInsights.Field.account_id,
    AdsInsights.Field.date_start,
    AdsInsights.Field.date_stop,
    AdsInsights.Field.frequency,    # frequência real nível conta
    AdsInsights.Field.impressions,
    AdsInsights.Field.reach,
]

PARAMS_ACCOUNT = {
    "level": "account",
    "time_increment": 1,
}


# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

def extract_action(actions: list | None, action_type: str) -> float:
    """Extrai o valor de uma action_type específica da lista da API."""
    if not actions:
        return 0.0
    for a in actions:
        if a.get("action_type") == action_type:
            return float(a.get("value", 0))
    return 0.0


def safe_div(a: float, b: float) -> float | None:
    return round(a / b, 6) if b and b > 0 else None


def paginate(cursor) -> list:
    """Percorre todas as páginas de um cursor da Meta API."""
    rows = []
    page = 0
    while True:
        page += 1
        batch = list(cursor)
        rows.extend(batch)
        log.info(f"  página {page}: +{len(batch)} → total {len(rows)}")
        if not cursor.load_next_page():
            break
        time.sleep(0.3)   # respeita rate limit
    return rows


# ─────────────────────────────────────────────────────────────
# Extração e transformação — anúncios
# ─────────────────────────────────────────────────────────────

TEAM_MEMBERS = ["Paulo", "Sabrina", "Viviane", "Jorge", "Diulia", "Julia", "César", "Cesar", "Anderson"]

def extract_creator(ad_name: str) -> str:
    """Extrai o nome do criador baseado na nomenclatura do anúncio."""
    if not ad_name:
        return "Sem identificação"
    ad_upper = ad_name.upper()
    for name in TEAM_MEMBERS:
        if name.upper() in ad_upper:
            return "César" if name in ("Cesar", "César") else name
    return "Sem identificação"


def calculate_metrics(row: dict) -> dict:
    """Transforma uma linha bruta da API nas métricas finais."""

    impressions  = int(row.get("impressions", 0) or 0)
    spend        = float(row.get("spend", 0) or 0)
    clicks       = int(row.get("clicks", 0) or 0)
    purchases    = int(extract_action(row.get("actions"), "purchase"))
    purchase_val = float(extract_action(row.get("action_values"), "purchase"))

    # ThruPlay (hook rate)
    thruplays = int(
        extract_action(row.get("video_thruplay_watched_actions"), "video_view")
    )

    # 30s watched (hold rate)
    video_views = int(
        extract_action(row.get("video_30_sec_watched_actions"), "video_view")
    )

    # outbound_ctr: Meta entrega como lista [{"action_type": "...", "value": "0.52"}]
    outbound_ctr_raw = row.get("outbound_clicks_ctr")
    if outbound_ctr_raw and isinstance(outbound_ctr_raw, list):
        outbound_ctr = float(outbound_ctr_raw[0].get("value", 0))
    else:
        outbound_ctr = None

    return {
        # Brutas
        "impressions":                       impressions,
        "spend":                             spend,
        "clicks":                            clicks,
        "purchases":                         purchases,
        "purchase_value":                    purchase_val,
        "video_thruplay_watched_actions":    thruplays,
        "video_watched_actions":             video_views,

        # Calculadas
        "cvr":           safe_div(clicks, impressions) * 100 if impressions else None,
        "cpa":           safe_div(spend, purchases),
        "roas":          safe_div(purchase_val, spend),
        "hook_rate":     safe_div(thruplays, impressions) * 100 if impressions else None,
        "hold_rate":     safe_div(video_views, impressions) * 100 if impressions else None,
        "cost_per_hook": round(spend / thruplays, 2) if thruplays > 0 else None,

        # Direto da API
        "outbound_ctr":  outbound_ctr,

        # Criador extraído da nomenclatura
        "creator": extract_creator(row.get("ad_name", "")),
    }


def fetch_ad_insights(date_start: str, date_stop: str) -> list[dict]:
    log.info(f"Buscando insights por anúncio: {date_start} → {date_stop}")
    account = AdAccount(AD_ACCOUNT_ID)
    cursor = account.get_insights(
        fields=FIELDS_AD,
        params={
            **PARAMS_AD,
            "time_range": {"since": date_start, "until": date_stop},
        },
    )
    raw = paginate(cursor)
    log.info(f"Total bruto (anúncios): {len(raw)} linhas")

    records = []
    for r in raw:
        r = dict(r)
        metrics = calculate_metrics(r)
        records.append({
            "ad_id":         r["ad_id"],
            "ad_name":       r.get("ad_name"),
            "adset_id":      r.get("adset_id"),
            "adset_name":    r.get("adset_name"),
            "campaign_id":   r.get("campaign_id"),
            "campaign_name": r.get("campaign_name"),
            "account_id":    r.get("account_id"),
            "date_start":      r["date_start"],
            "date_stop":       r["date_stop"],
            "ad_created_time": r.get("created_time", "")[:10] if r.get("created_time") else None,
            **metrics,
        })

    return records


# ─────────────────────────────────────────────────────────────
# Extração — frequência da conta
# ─────────────────────────────────────────────────────────────

def fetch_account_frequency(date_start: str, date_stop: str) -> list[dict]:
    log.info(f"Buscando frequência da conta: {date_start} → {date_stop}")
    account = AdAccount(AD_ACCOUNT_ID)
    cursor = account.get_insights(
        fields=FIELDS_ACCOUNT,
        params={
            **PARAMS_ACCOUNT,
            "time_range": {"since": date_start, "until": date_stop},
        },
    )
    raw = paginate(cursor)

    records = []
    for r in raw:
        r = dict(r)
        records.append({
            "account_id":  r.get("account_id", AD_ACCOUNT_ID),
            "date_start":  r["date_start"],
            "date_stop":   r["date_stop"],
            "frequency":   float(r.get("frequency", 0) or 0),
            "impressions": int(r.get("impressions", 0) or 0),
            "reach":       int(r.get("reach", 0) or 0),
        })

    log.info(f"Frequência da conta: {len(records)} dias")
    return records


# ─────────────────────────────────────────────────────────────
# Carga no Supabase
# ─────────────────────────────────────────────────────────────

BATCH_SIZE = 500

def upsert(table: str, records: list[dict], conflict_cols: str):
    if not records:
        log.warning(f"Nenhum registro para upsert em {table}")
        return
    for i in range(0, len(records), BATCH_SIZE):
        batch = records[i:i + BATCH_SIZE]
        supabase.table(table).upsert(
            batch,
            on_conflict=conflict_cols,
        ).execute()
        log.info(f"  upsert {table} batch {i // BATCH_SIZE + 1}: {len(batch)} linhas")


def update_monthly_summary():
    """Chama a stored procedure que recalcula o resumo mensal."""
    supabase.rpc("refresh_meta_monthly_summary").execute()
    log.info("Resumo mensal atualizado")


# ─────────────────────────────────────────────────────────────
# Pipeline principal
# ─────────────────────────────────────────────────────────────

def run(days_back: int = 7):
    end   = datetime.today().date()
    start = end - timedelta(days=days_back)
    log.info(f"══ Iniciando ETL: {start} → {end} ({days_back} dias) ══")

    # 1. Insights por anúncio
    ad_records = fetch_ad_insights(str(start), str(end))
    upsert("meta_ads_insights", ad_records, "ad_id,date_start,date_stop")

    # 2. Frequência da conta
    freq_records = fetch_account_frequency(str(start), str(end))
    upsert("meta_account_frequency", freq_records, "account_id,date_start")

    # 3. Recalcula resumo mensal (campeões incluídos)
    update_monthly_summary()

    log.info("══ ETL finalizado com sucesso ══")


# ─────────────────────────────────────────────────────────────
# Entrypoint
# ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
    run(days_back=days)
