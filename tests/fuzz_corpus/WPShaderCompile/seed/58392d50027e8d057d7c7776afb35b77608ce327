
// [COMBO] {"material":"My Combo Name","combo":"USERCOMBOIDENTIFIER","type":"options","default":0}

uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
uniform vec4 g_Texture0Resolution;

uniform vec2 g_PointerPosition;
uniform vec2 g_TexelSize;
uniform float g_Time;

varying vec2 v_TexCoord;
varying vec2 v_Position;

mat2 rot2D(float angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return mat2(c, -s, s, c);
}

vec3 rot3D(vec3 p, vec3 axis, float angle)
{
    return mix(dot(axis,p) * axis, p, cos(angle)) + cross(axis,p) * sin(angle);
}
float sdSPhere(vec3 p, float radius)
{
    return length(p) - radius;
}

float sdSPhere(vec3 p, vec3 pos, float radius)
{
    return length(p - pos) - radius;
}

float sdBox(vec3 p, vec3 b, vec3 pos)
{
    vec3 q = abs(p - pos) - b;
    return length(max(q,0.)) + min(max(q.x, max(q.y, q.z)), 0.);
}

float sdOctahedron(vec3 p, float s)
{
    p = abs(p);
    return (p.x + p.y + p.z - s) * .57735027;
}

float sdLink( vec3 p, float le, float r1, float r2 )
{
  vec3 q = vec3( p.x, max(abs(p.y)-le,0.0), p.z );
  return length(vec2(length(q.xy)-r1,q.z)) - r2;
}

float opSmoothUnion(float d1, float d2, float k)
{
    float h = clamp(0.5 +  0.5*(d2-d1)/k, 0.1, 1.0);
    return mix(d2,d1,h) - k*h*(1. - h);
}

float smin(float a, float b, float k)
{
    float h = max(k - abs(a-b), 0.)/k;
    return min(a,b) - h*h*h*k*(1./6.);
}



float map(vec3 p)
{
    vec3 spherePos = vec3(- 15. + frac(g_Time * .1) * 30.,0.,0.);
    float sphere = sdSPhere(p, spherePos, 1.);

    vec3 q = p;
    q.y -= g_Time * .4;
    q = frac(q) - .5;

    q.xy =  mul(q.xy,rot2D(g_Time * 4.)); //rotate around the z axis
    float box = sdBox(q, vec3(.1, .1, .1), vec3(0., 0., 0.));
    float ground = p.y + .75;

    return smin(ground, smin(sphere,box, 2.), 1.);
}

float map2(vec3 p)
{
    // animate
    p.z += 0.5*g_Time;
    p.x -= .08 *cos(g_Time);
    p.y += .08 *sin(g_Time);

     p.xy = (frac(p.xy) - .5);
    // paramteres
    const float le = 0.17, r1 = 0.12, r2 = 0.05;
    
    // make a chain out of sdLink's
    vec3 a = p; a.z = frac(a.z    )-0.5;
    vec3 b = p; b.z = frac(b.z+0.5)-0.5;
    
    //a.yz *= rot2D(u_time) ;
    //b.yz *= rot2D(u_time);
    // evaluate two links
    return min(sdLink(a.xzy,le,r1,r2),
               sdLink(b.yzx,le,r1,r2));
}

vec3 calcNormal( in vec3 pos )
{
    vec2 e = vec2(1.0,-1.0)*0.5773;
    const float eps = 0.0005;
    return normalize( e.xyy*map( pos + e.xyy*eps ) + 
					  e.yyx*map( pos + e.yyx*eps ) + 
					  e.yxy*map( pos + e.yxy*eps ) + 
					  e.xxx*map( pos + e.xxx*eps ) );
}

float calcSoftshadow( in vec3 ro, in vec3 rd, in float mint, in float tmax )
{
    float res = 1.0;
    float t = mint;
    for( int i=0; i<16; i++ )
    {
		float h = map2( ro + rd *t );
        res = min( res, 8.0*h/t );
        t += clamp( h, 0.02, 0.10 );
        if( res<0.005 || t>tmax ) break;
    }
    return clamp( res, 0.0, 1.0 );
}

vec3 palette(float t)
{
    vec3 a = vec3(0.5255, 0., 0.0);
    vec3 b = vec3(0.5608, 0., 0.1333);
    vec3 c = vec3(0.6784, 0., 0.3333);
    vec3 d = vec3(0.1176, 0., 0.1216);
    return a + b*cos(6.28318*(c*t+d));
}


#define AA 1

void main()
{

    vec3 tot = CAST3(0.);
    for( int m=0; m<AA; m++ )
    for( int n=0; n<AA; n++ )
    {
        vec2 o = vec2(float(m),float(n)) / float(AA) - 0.5;
        //vec2 uv = (2.* v_Position.xy - g_Texture0Resolution.xy) / g_Texture0Resolution.y;
        vec2 uv = 2* (v_Position + o/2) / g_Texture0Resolution.y;
        //vec2 uv = v_TexCoord;
        vec2 m = g_PointerPosition.xy; /*2. / g_Texture0Resolution.y;*/
        float fov = .5;
        //Initialize ray
        //float fov = .5;
        //Initialize ray
        vec3 ro = vec3(0.,0.,-3.); //ray origin
        vec3 rd = normalize(vec3(uv * fov,1.)); //ray direction
        vec3 col = vec3(0.0, 0.0, 0.0);

        float t = 0.; //travelled distance
        //float tmax = 80.;
        //Camera rotation
        //ro.yz *= rot2D(-m.y);
    // rd.yz *= rot2D(-m.y);

        //ro.xz *= rot2D(-m.x);
        //rd.xz *= rot2D(-m.x);

        
        //Raymarching
        int j;
        for(int i = 0; i<128; ++i)
        {
            vec3 p = ro + rd * t; //position along ray
            p.xy = mul(p.xy,rot2D(t * 0.2));// rolling the ray
            p.y += sin(0.8 * t) * .05; //wiggle ray

            float d = map2(p); //current distance to the scene
            t += d;

            //col = vec3(i) /80.;
            j = i;
            if(d< 0.001 || t > 50.) break; //early stop when close enough & avoid going too far
        }

        vec3 pos = ro + t*rd;
        pos.xy = mul(pos.xy,rot2D(t * 0.2));
        pos.y += sin(0.8 * t) * .05; //apply ray deformation 
        vec3 nor = calcNormal(pos);
        vec3 lig = normalize(vec3(0.8471, 0.4824, 0.0667));
        vec3 hal = normalize(lig-rd);
        float dif = clamp( dot(nor,lig), 0.0, 1.0 );
        //float occ = calcOcclusion( pos, nor );
        //pos.xy *= rot2D(t * 0.15);
        //if( dif>0.001 )dif *= calcSoftshadow( pos, lig, 0.01, 1.0 );
        float spe = pow(clamp(dot(nor,hal),0.0,1.0),16.0)*dif*(0.04+0.96*pow(clamp(1.0-dot(hal,-rd),0.0,1.0),5.0));
        float amb = 0.5 + 0.5*dot(nor,vec3(0.0,1.0,0.0));
        //pos.xy *= rot2D(t * 0.15);
        
        col = CAST3(.9 + calcSoftshadow( pos, lig, 0.01, 1.0 ) / 1.9);
        //col =  vec3(0.5,1.0,1.2)*amb*occ;
        //col += vec3(2.8,2.2,1.8)*dif;
        
        //col *= 0.2;
        
        //col += vec3(2.8,2.2,1.8)*spe*3.0;
        //coloring
        //col = vec3(float(j) / 80.);
        //col = sqrt( col / length(col) );
        col *= palette(float(j)*.005);
        // vignetting
        col *= (1.0-0.5*dot(uv,uv));
        tot += col;
    }
    tot /= float(AA*AA);
    gl_FragColor = vec4(tot, 1.);
}
