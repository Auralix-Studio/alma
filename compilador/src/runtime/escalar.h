/* Runtime escalar del backend de arranque. Los registros poseen sus valores;
 * las operaciones toman préstamos y devuelven un valor propio. */
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

typedef struct { size_t referencias; char datos[]; } Texto;
typedef enum { T_INDEFINIDO, T_NULO, T_ENT, T_DEC, T_LOG, T_TXT } Tag;
typedef struct {
    Tag tag;
    union {
        int64_t ent;
        double dec;
        bool logv;
        struct { const char* datos; size_t longitud; Texto* dueno; } texto;
    };
} Val;

static size_t alma_textos_vivos = 0;
static Val nulo(void){ Val v={0}; v.tag=T_NULO; return v; }
static Val indefinido(void){ Val v={0}; return v; }
static Val ent(int64_t n){ Val v={0}; v.tag=T_ENT; v.ent=n; return v; }
static Val dec(double n){ Val v={0}; v.tag=T_DEC; v.dec=n; return v; }
static Val dec_bits(uint64_t bits){ double n; memcpy(&n,&bits,sizeof n); return dec(n); }
static Val logv(bool b){ Val v={0}; v.tag=T_LOG; v.logv=b; return v; }
static Val txt_lit(const char* s,size_t n){ Val v={0}; v.tag=T_TXT; v.texto.datos=s; v.texto.longitud=n; return v; }
static const char* alma_archivo = "programa";
static size_t alma_linea = 0, alma_columna = 0;
static _Noreturn void alma_error(const char* mensaje){ fprintf(stderr,"%s:%zu:%zu: %s\n",alma_archivo,alma_linea,alma_columna,mensaje); exit(1); }
static size_t alma_profundidad_llamadas = 0;
static void alma_entrar_llamada(void){
    if(alma_profundidad_llamadas>=ALMA_LIMITE_LLAMADAS) alma_error("desbordamiento de pila");
    alma_profundidad_llamadas++;
}
static Val alma_leer(Val v){ if(v.tag==T_INDEFINIDO) alma_error("variable no definida"); return v; }
static Val alma_retener(Val v){
    v=alma_leer(v);
    if(v.tag==T_TXT && v.texto.dueno){
        if(v.texto.dueno->referencias==SIZE_MAX) alma_error("demasiadas referencias");
        v.texto.dueno->referencias++;
    }
    return v;
}
static void alma_soltar(Val* v){
    if(v->tag==T_TXT && v->texto.dueno && --v->texto.dueno->referencias==0){
        free(v->texto.dueno);
        alma_textos_vivos--;
    }
    *v=nulo();
}
static void alma_guardar(Val* destino,Val propio){ alma_soltar(destino); *destino=propio; }
static Val alma_retornar(Val* registros,size_t n,size_t origen){
    Val resultado=alma_retener(registros[origen]);
    for(size_t i=0;i<n;i++) alma_soltar(&registros[i]);
    alma_profundidad_llamadas--;
    return resultado;
}
static Val texto_nuevo(size_t longitud){
    if(longitud>SIZE_MAX-sizeof(Texto)-1) alma_error("texto demasiado grande");
#ifdef ALMA_LIMITE_TEXTOS
    if(alma_textos_vivos>=ALMA_LIMITE_TEXTOS) alma_error("límite de textos vivos excedido");
#endif
    Texto* t=malloc(sizeof(Texto)+longitud+1);
    if(!t) alma_error("sin memoria");
    t->referencias=1; t->datos[longitud]=0; alma_textos_vivos++;
    Val v=txt_lit(t->datos,longitud); v.texto.dueno=t; return v;
}
static double as_num(Val v){
    if(v.tag==T_DEC) return v.dec;
    if(v.tag==T_ENT) return (double)v.ent;
    alma_error("la operación requiere números");
}
static bool as_bool(Val v){ if(v.tag!=T_LOG) alma_error("se requiere un valor lógico"); return v.logv; }
static bool ambos_ent(Val a,Val b){ return a.tag==T_ENT && b.tag==T_ENT; }
static Val entero_sumar(int64_t a,int64_t b){ int64_t r; if(__builtin_add_overflow(a,b,&r)) alma_error("desbordamiento de entero"); return ent(r); }
static Val entero_restar(int64_t a,int64_t b){ int64_t r; if(__builtin_sub_overflow(a,b,&r)) alma_error("desbordamiento de entero"); return ent(r); }
static Val entero_multiplicar(int64_t a,int64_t b){ int64_t r; if(__builtin_mul_overflow(a,b,&r)) alma_error("desbordamiento de entero"); return ent(r); }
static Val alma_mas(Val a,Val b){
    if(a.tag==T_TXT && b.tag==T_TXT){
        size_t na=a.texto.longitud, nb=b.texto.longitud;
        if(na>SIZE_MAX-nb) alma_error("texto demasiado grande");
        Val r=texto_nuevo(na+nb);
        memcpy(r.texto.dueno->datos,a.texto.datos,na);
        memcpy(r.texto.dueno->datos+na,b.texto.datos,nb);
        return r;
    }
    if(ambos_ent(a,b)) return entero_sumar(a.ent,b.ent);
    return dec(as_num(a)+as_num(b));
}
static Val alma_menos(Val a,Val b){ return ambos_ent(a,b)?entero_restar(a.ent,b.ent):dec(as_num(a)-as_num(b)); }
static Val alma_por(Val a,Val b){ return ambos_ent(a,b)?entero_multiplicar(a.ent,b.ent):dec(as_num(a)*as_num(b)); }
static Val alma_entre(Val a,Val b){
    double x=as_num(a), y=as_num(b);
    if(y==0) alma_error("división por cero");
    if(ambos_ent(a,b)){
        if(a.ent==INT64_MIN && b.ent==-1) alma_error("desbordamiento de entero");
        return ent(a.ent/b.ent);
    }
    return dec(x/y);
}
static Val alma_modulo(Val a,Val b){
    if(!ambos_ent(a,b)) alma_error("'%' requiere enteros");
    if(b.ent==0) alma_error("módulo por cero");
    if(a.ent==INT64_MIN && b.ent==-1) return ent(0);
    return ent(a.ent % b.ent);
}
static Val alma_neg(Val a){ if(a.tag==T_ENT) return entero_restar(0,a.ent); return dec(-as_num(a)); }
static Val alma_no(Val a){ return logv(!as_bool(a)); }
static Val alma_logico(Val a){ return logv(as_bool(a)); }
static Val alma_menor(Val a,Val b){ return logv(ambos_ent(a,b)?a.ent<b.ent:as_num(a)<as_num(b)); }
static Val alma_mayor(Val a,Val b){ return logv(ambos_ent(a,b)?a.ent>b.ent:as_num(a)>as_num(b)); }
static Val alma_menor_ig(Val a,Val b){ return logv(ambos_ent(a,b)?a.ent<=b.ent:as_num(a)<=as_num(b)); }
static Val alma_mayor_ig(Val a,Val b){ return logv(ambos_ent(a,b)?a.ent>=b.ent:as_num(a)>=as_num(b)); }
static bool val_ig(Val a,Val b){
    if(ambos_ent(a,b)) return a.ent==b.ent;
    if((a.tag==T_ENT||a.tag==T_DEC)&&(b.tag==T_ENT||b.tag==T_DEC)) return as_num(a)==as_num(b);
    if(a.tag!=b.tag) return false;
    if(a.tag==T_TXT) return a.texto.longitud==b.texto.longitud && memcmp(a.texto.datos,b.texto.datos,a.texto.longitud)==0;
    if(a.tag==T_LOG) return a.logv==b.logv;
    return true;
}
static Val alma_igual(Val a,Val b){ return logv(val_ig(a,b)); }
static Val alma_distinto(Val a,Val b){ return logv(!val_ig(a,b)); }
static Val alma_texto(Val v){
    char buffer[64]; int longitud;
    switch(v.tag){
        case T_TXT: return alma_retener(v);
        case T_NULO: return txt_lit("nulo",4);
        case T_LOG: return v.logv?txt_lit("verdadero",9):txt_lit("falso",5);
        case T_ENT: longitud=snprintf(buffer,sizeof buffer,"%lld",(long long)v.ent); break;
        case T_DEC: longitud=snprintf(buffer,sizeof buffer,"%g",v.dec); break;
        default: alma_error("valor no definido");
    }
    if(longitud<0 || (size_t)longitud>=sizeof buffer) alma_error("error de formato numérico");
    Val r=texto_nuevo((size_t)longitud);
    memcpy(r.texto.dueno->datos,buffer,(size_t)longitud);
    return r;
}
static void alma_escribir(Val v){
    switch(v.tag){
        case T_ENT: if(fprintf(stdout,"%lld",(long long)v.ent)<0) alma_error("error de salida"); break;
        case T_DEC: if(fprintf(stdout,"%g",v.dec)<0) alma_error("error de salida"); break;
        case T_TXT: if(fwrite(v.texto.datos,1,v.texto.longitud,stdout)!=v.texto.longitud) alma_error("error de salida"); break;
        case T_LOG: if(fputs(v.logv?"verdadero":"falso",stdout)==EOF) alma_error("error de salida"); break;
        case T_NULO: if(fputs("nulo",stdout)==EOF) alma_error("error de salida"); break;
        default: alma_error("valor no definido");
    }
}
static Val alma_imprimir(int n,...){
    va_list ap; va_start(ap,n);
    for(int i=0;i<n;i++){ if(i>0 && fputc(' ',stdout)==EOF) alma_error("error de salida"); alma_escribir(va_arg(ap,Val)); }
    va_end(ap);
    if(fputc('\n',stdout)==EOF || fflush(stdout)==EOF) alma_error("error de salida");
    return nulo();
}
